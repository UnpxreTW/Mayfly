//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// host 側「等 guest 回報 provisioning 完成」的閘。消費 guest serial console 輸出行
/// （``MacGuestConfigurationBuilder/Console`` 那條 output handle 的讀端），偵測 first-boot
/// daemon 發的 `PROVISIONING_READY user=<u> ip=<ip>` marker——**主訊號、完全不經 host
/// 網路、繞開 Local Network TCC**。marker 的 `ip` 為 `none` / 缺時，以 guest MAC 對 host
/// `dhcpd_leases` 做 byte-match 備援解 IP，產出 ``Readiness`` 的 `AsyncStream`。
///
/// **lease 備援會輪詢**：marker 是 first-boot daemon 一次性發（發完自刪），若 IP 在 marker
/// 那一刻還沒進 host lease（DHCP 常比 marker 晚幾秒），讀一次就放棄會終局回 `nil`。故 `ip=none`
/// 時以 bounded backoff 輪詢 lease 到解出或逾時（逾時才 best-effort 回 `nil`）。
///
/// console 行來源與 lease 讀取都**注入**：餵假行序列 + 假 lease 內容即可純測 parser、輪詢與
/// 狀態機、不必開真 VM。真實接線＝把 console output handle 的 `bytes.lines` 橋成
/// `AsyncStream<String>`（薄殼、由呼叫端組）。範圍到 `provisioningReady(ip)`；SSH port 實際
/// 開放是 connect 路徑的 TCP 探測、不在此。
public struct ReadinessGate: Sendable {

	// MARK: Public

	/// 消費 console 行、產 ``Readiness`` 流：先 `booting`，偵到 `PROVISIONING_READY` 即以
	/// marker 的 ip（或 lease 備援輪詢）發 `provisioningReady(ip:)` 後結束。console 行來源結束
	/// （或無 marker）時流亦結束——逾時由呼叫端自負（真 console 在等 marker 時不會自行結束）。
	public func readiness(consoleLines: AsyncStream<String>) -> AsyncStream<Readiness> {
		AsyncStream { continuation in
			let task = Task {
				continuation.yield(.booting)
				for await line in consoleLines {
					guard let marker = Self.parseMarker(line: line) else {
						continue
					}
					await continuation.yield(.provisioningReady(ip: resolveIP(markerIP: marker.ip)))
					break
				}
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
				let value: String = .init(line.dropFirst("hw_address=".count))
				let mac = value.split(separator: ",").last.map(String.init) ?? value
				if normalizedMAC(mac) == target, let ip = currentIP {
					return ip
				}
			}
		}
		return nil
	}

	// MARK: Private

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

	/// 待比對的 guest MAC（lease 備援用；nil 則備援必然解不出）。
	private let macAddress: String?

	/// host `dhcpd_leases` 內容讀取器（預設讀 `/var/db/dhcpd_leases`、測試注入假）。
	private let readLeases: @Sendable () -> String?

	/// lease 備援輪詢間隔（ms）。
	private let leaseResolvePollMilliseconds: Int

	/// lease 備援輪詢總上限（ms、超過回 nil、best-effort）。
	private let leaseResolveTimeoutMilliseconds: Int

	/// marker 已帶 ip 就直接用；`ip=none` 時以 bounded backoff 輪詢 host lease 解 IP（lease 可能
	/// 比 marker 晚幾秒才出現、不該讀一次就放棄），逾時回 nil（best-effort）。Task 取消時中止回 nil。
	private func resolveIP(markerIP: String?) async -> String? {
		if let markerIP {
			return markerIP
		}
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
