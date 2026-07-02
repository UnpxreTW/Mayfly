//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// host 側「等 guest 回報 provisioning 完成」的閘。開場發 `booting`，然後**兩路競速**解出
/// guest IP、先到者發 `provisioningReady(ip:)`：
///
/// - **console marker（optional fast-path）**：偵 guest serial console 的 first-boot daemon
///   marker `PROVISIONING_READY user=<u> ip=<ip>`。不經 host 網路、繞開 Local Network TCC；
///   但**實機驗證發現 macOS guest 的 `/dev/console` 未必路由到 VZVirtioConsole serial**（marker
///   可能永遠不出現）——故只當「有就更快」的機會路徑、不倚賴。
/// - **lease 輪詢（可靠主路徑）**：以 guest MAC 對 host `dhcpd_leases` 做 per-byte radix:16
///   byte-match（lease 檔省略前導零）解 IP。同樣 TCC-free（host 讀自己的 lease 檔、非對 guest
///   發網路），且給的是 SSH 真正要的 IP。marker 可能永久無輸出，故 lease 輪詢與逾時 guard
///   保證整體有界。到逾時仍無 IP → `provisioningReady(ip: nil)`（best-effort）。
///
/// console 行來源與 lease 讀取都**注入** → 餵假行序列 + 假 lease 內容即可純測 parser、競速與
/// 狀態機、不必開真 VM。真實接線＝把 console output handle 的 `bytes.lines` 橋成
/// `AsyncStream<String>`（薄殼、呼叫端組）。範圍到 `provisioningReady(ip)`；SSH port 實際開放
/// 是 connect 路徑的 TCP 探測、不在此。
public struct ReadinessGate: Sendable {

	// MARK: Public

	/// 開場發 `booting`，兩路競速（console marker + lease 輪詢）解 IP、先到者發
	/// `provisioningReady(ip:)` 後結束；到逾時仍無 IP 則發 `provisioningReady(ip: nil)`。
	public func readiness(consoleLines: AsyncStream<String>) -> AsyncStream<Readiness> {
		AsyncStream { continuation in
			let task = Task {
				continuation.yield(.booting)
				await continuation.yield(.provisioningReady(ip: firstResolvedIP(consoleLines: consoleLines)))
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	public init(
		macAddress: String?,
		readLeases: @escaping @Sendable () -> String? = {
			try? String(contentsOf: URL(fileURLWithPath: "/var/db/dhcpd_leases"), encoding: .utf8)
		},
		leaseResolvePollMilliseconds: Int = 500,
		leaseResolveTimeoutMilliseconds: Int = 10_000
	) {
		self.macAddress = macAddress
		self.readLeases = readLeases
		self.leaseResolvePollMilliseconds = leaseResolvePollMilliseconds
		self.leaseResolveTimeoutMilliseconds = leaseResolveTimeoutMilliseconds
	}

	// MARK: Internal

	/// 從一行 console 輸出解 `PROVISIONING_READY` marker 的 user + ip（`ip=none` → `nil`）。
	/// 以 whitespace 分詞找 `user=` / `ip=`、容忍行首雜訊；非 marker 行或缺 user 回 nil。純函式。
	static func parseMarker(line: String) -> (user: String, ip: String?)? {
		guard line.contains("PROVISIONING_READY") else {
			return nil
		}
		var user: String?
		var ip: String?
		for token in line.split(whereSeparator: \.isWhitespace) {
			if token.hasPrefix("user=") {
				user = String(token.dropFirst("user=".count))
			} else if token.hasPrefix("ip=") {
				let value: String = .init(token.dropFirst("ip=".count))
				ip = value == "none" ? nil : value
			}
		}
		guard let user, !user.isEmpty else {
			return nil
		}
		return (user: user, ip: ip)
	}

	/// 從 `dhcpd_leases` 內容以 guest MAC byte-match 解 IP。兩邊 MAC 皆 per-byte radix:16
	/// 正規化（lease 檔省略前導零：`a:1b:2` == `0a:1b:02`），去掉 `hw_address=<type>,` 的 type
	/// 前綴。每個 `{}` 區塊在 `{` 重置 IP、避免缺 `ip_address` 的區塊誤用前一塊的值。找不到 /
	/// MAC 空 / MAC 非法回 nil。純函式。
	static func resolveLeaseIP(fromLeases content: String, matching macAddress: String) -> String? {
		let target = normalizedMAC(macAddress)
		guard !target.isEmpty else {
			return nil
		}
		var currentIP: String?
		for rawLine in content.split(whereSeparator: \.isNewline) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line == "{" {
				currentIP = nil
			} else if line.hasPrefix("ip_address=") {
				currentIP = String(line.dropFirst("ip_address=".count))
			} else if line.hasPrefix("hw_address=") {
				let value = line.dropFirst("hw_address=".count).split(separator: ",").last.map(String.init) ?? ""
				if normalizedMAC(value) == target, let ip = currentIP {
					return ip
				}
			}
		}
		return nil
	}

	// MARK: Private

	/// 一路競速的結果：`resolved` 帶解出的 IP（可能 nil＝該路無 IP、等其他路）、`timedOut`＝整體逾時。
	private enum Resolution {

		case resolved(String?)

		case timedOut
	}

	/// MAC 拆冒號、每段 radix:16 解 byte。**任一段非法 hex → 回空**（不做掉段後的部分比對，杜絕
	/// wrong-host 的長度巧合命中）。
	private static func normalizedMAC(_ mac: String) -> [Int] {
		let segments = mac.split(separator: ":")
		let bytes = segments.compactMap { Int($0, radix: 16) }
		guard bytes.count == segments.count else {
			return []
		}
		return bytes
	}

	/// 待比對的 guest MAC（lease 解析用；nil 則 lease 路必然解不出）。
	private let macAddress: String?

	/// host `dhcpd_leases` 內容讀取器（預設讀 `/var/db/dhcpd_leases`、測試注入假）。
	private let readLeases: @Sendable () -> String?

	/// lease 輪詢間隔（ms）。
	private let leaseResolvePollMilliseconds: Int

	/// lease 輪詢 + console 等待的整體上限（ms、超過回 nil、best-effort）。
	private let leaseResolveTimeoutMilliseconds: Int

	/// 兩路競速解 IP：console marker（機會路徑）+ lease 輪詢（可靠）；先解出非 nil IP 者勝。
	/// console watch 可能永久無輸出（實機 `/dev/console` 未必路由到 virtio serial），故獨立的
	/// 逾時 guard 保證有界——到逾時仍無 IP 回 nil。任一路的 nil 不作數、等其他路。
	private func firstResolvedIP(consoleLines: AsyncStream<String>) async -> String? {
		await withTaskGroup(of: Resolution.self) { group in
			group.addTask { await .resolved(consoleMarkerIP(consoleLines: consoleLines)) }
			group.addTask { await .resolved(pollLeaseIP()) }
			group.addTask {
				try? await Task.sleep(for: .milliseconds(leaseResolveTimeoutMilliseconds))
				return .timedOut
			}
			defer { group.cancelAll() }
			for await outcome in group {
				switch outcome {
				case let .resolved(ip?):
					return ip
				case .resolved:
					continue
				case .timedOut:
					return nil
				}
			}
			return nil
		}
	}

	/// console marker 路徑：偵到 marker 且帶 ip 即回；`ip=none` 或流結束回 nil（IP 交給 lease 路）。
	private func consoleMarkerIP(consoleLines: AsyncStream<String>) async -> String? {
		for await line in consoleLines {
			guard let marker = Self.parseMarker(line: line) else {
				continue
			}
			return marker.ip
		}
		return nil
	}

	/// lease 輪詢：以 bounded backoff 讀 host lease 解 IP、到逾時回 nil。Task 取消時中止回 nil。
	private func pollLeaseIP() async -> String? {
		var elapsedMS = 0
		while true {
			if let ip = Self.resolveLeaseIP(fromLeases: readLeases() ?? "", matching: macAddress ?? "") {
				return ip
			}
			guard elapsedMS < leaseResolveTimeoutMilliseconds else {
				return nil
			}
			do {
				try await Task.sleep(for: .milliseconds(leaseResolvePollMilliseconds))
			} catch {
				return nil
			}
			// 保證前進：poll=0 的誤設也不會讓 elapsed 卡住成無限迴圈。
			elapsedMS += max(leaseResolvePollMilliseconds, 1)
		}
	}

}
