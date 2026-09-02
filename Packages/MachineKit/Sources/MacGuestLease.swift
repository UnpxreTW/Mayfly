//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 以 guest MAC 反查 host DHCP lease 的 IP——`dhcpd_leases` 解析的單一正本。
///
/// ``ReadinessGate`` 的 lease 輪詢與外殼層的即時查詢（CLI `ip`、MCP status）都
/// 消費這裡：TCC-free（host 讀自己的 lease 檔、非對 guest 發網路），給的是 SSH
/// 真正要的 IP。純 Foundation、無 arch gate。
public enum MacGuestLease {

	/// 從 `dhcpd_leases` 內容以 guest MAC byte-match 解 IP。兩邊 MAC 皆 per-byte
	/// radix:16 正規化（lease 檔省略前導零：`a:1b:2` == `0a:1b:02`），去掉
	/// `hw_address=<type>,` 的 type 前綴。每個 `{}` 區塊在 `{` 重置 IP、避免缺
	/// `ip_address` 的區塊誤用前一塊的值。找不到 / MAC 空 / MAC 非法回 nil。純函式。
	public static func resolveIP(fromLeases content: String, matching macAddress: String) -> String? {
		let target = normalizedMAC(macAddress)
		guard !target.isEmpty else { return nil }
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

	/// 單次快照：讀 host lease 檔、反查該 MAC 現時的 IP。檔不存在 / 不可讀回 nil。
	/// 不輪詢、不等待——等待語義屬 ``ReadinessGate``。
	public static func currentIP(
		macAddress: String,
		leasesFile: URL = URL(fileURLWithPath: "/var/db/dhcpd_leases")
	) -> String? {
		guard let content = try? String(contentsOf: leasesFile, encoding: .utf8) else { return nil }
		return resolveIP(fromLeases: content, matching: macAddress)
	}

	// MARK: Private

	/// MAC 拆冒號、每段 radix:16 解 byte。**任一段非法 hex → 回空**（不做掉段後的
	/// 部分比對，杜絕 wrong-host 的長度巧合命中）。
	private static func normalizedMAC(_ mac: String) -> [Int] {
		let segments = mac.split(separator: ":")
		let bytes = segments.compactMap { Int($0, radix: 16) }
		guard bytes.count == segments.count else { return [] }
		return bytes
	}
}
