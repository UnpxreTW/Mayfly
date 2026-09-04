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
import NymphKit

/// `mayfly destroy <target>`：過載——**NY-2 拍板**依 nymph socket 連通性消歧：
///
/// - **socket 在（daemon 在跑）** → `<target>` 當 **session id**：向 daemon 送 destroy（停 VM +
///   刪 clone + 移出 table）。
/// - **socket 不在** → `<target>` 當 **clone 路徑**：standalone 銷毀可拋複本（只收標 ephemeral
///   的 bundle——golden 與任意路徑包不成 ``EphemeralBundle``、這路刪不到 golden）。
struct DestroyCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "destroy",
		abstract: "Destroy a session by id (daemon up) or a disposable clone by path (daemon down).",
		discussion: """
		Disambiguated by the nymph socket (NY-2): when the daemon is running the argument is a \
		session id; otherwise it is a clone path made by `mayfly clone`.
		"""
	)

	/// daemon 在→session id；daemon 不在→clone 路徑。
	@Argument(help: "Session id (daemon up) or clone path (daemon down).")
	var target: String

	/// daemon 路徑限定：優雅停機（ensureStopped）而非硬停。
	@Flag(name: .customLong("no-force"), help: "Graceful stop instead of force (daemon id path only).")
	var noForce = false

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	func run() async throws {
		guard NymphClient.isDaemonPresent() else {
			let clone: EphemeralBundle = try .load(from: URL(fileURLWithPath: target))
			try MacGuestCloner().destroy(clone)
			return
		}
		switch try await NymphClientSupport.send(.destroy(DestroyParams(id: target, force: !noForce))) {
		case let .destroy(result):
			CommandOutput.write("\(result.id) destroyed")

		case let .toolError(error):
			throw NymphClientSupport.fail(error)

		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
