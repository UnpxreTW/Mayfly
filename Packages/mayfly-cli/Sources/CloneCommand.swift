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

/// `mayfly clone <golden> <destination>`：golden 的 CoW 可拋複本（MAC 已再生、
/// 標 ephemeral）。成功時印複本路徑一行。
struct CloneCommand: ParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "clone",
		abstract: "Clone a golden bundle into a disposable copy (CoW, same APFS volume)."
	)

	/// golden bundle 路徑（驗佈局、拒收已標 ephemeral 的複本回鍋）。
	@Argument(help: "Path to the golden guest bundle.")
	var golden: String

	/// 複本目的地（不得已存在；須與 golden 同一 APFS 卷）。
	@Argument(help: "Destination path for the clone (same APFS volume as the golden).")
	var destination: String

	func run() throws {
		let bundle: GoldenBundle = try .load(from: URL(fileURLWithPath: golden))
		let clone: EphemeralBundle = try GuestCloner().clone(bundle, to: URL(fileURLWithPath: destination))
		print(clone.bundle.path)
	}
}
