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

/// `mayfly destroy <clone>`：銷毀可拋複本。只收標了 ephemeral 的 bundle——golden
/// 與任意路徑包不成 ``EphemeralBundle``，CLI 這一路也刪不到 golden。
struct DestroyCommand: ParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "destroy",
		abstract: "Destroy a disposable clone (refuses anything not marked ephemeral)."
	)

	/// 可拋複本路徑（`mayfly clone` 的產物）。
	@Argument(help: "Path to a disposable clone (made by `mayfly clone`).")
	var bundle: String

	func run() throws {
		let clone: EphemeralBundle = try .load(from: URL(fileURLWithPath: bundle))
		try GuestCloner().destroy(clone)
	}
}
