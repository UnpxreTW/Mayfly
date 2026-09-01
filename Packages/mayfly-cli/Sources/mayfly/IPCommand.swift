//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import MachineKit

/// `mayfly ip <bundle>`：以 bundle 的 MAC 反查 host DHCP lease 現時 IP。命中印 IP
/// 一行、無 lease 靜默 exit 1（輪詢場景「還沒有」是常態、不是錯誤敘事）。
struct IPCommand: ParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "ip",
		abstract: "Print the current DHCP lease IP for a bundle (resolved by its MAC)."
	)

	/// bundle 路徑（golden 或複本皆可——只讀 metadata、純查詢）。
	@Argument(help: "Path to a guest bundle.")
	var bundle: String

	func run() throws {
		let metadataURL: URL = MacGuestBundleLayout.metadata(in: URL(fileURLWithPath: bundle))
		let metadata = try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: metadataURL))
		guard let ip = MacGuestLease.currentIP(macAddress: metadata.macAddress) else {
			throw ExitCode(1)
		}
		print(ip)
	}
}
