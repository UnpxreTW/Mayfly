//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import NymphKit

/// `mayfly spawn <golden>`（daemon client）：向 nymph 要一台可拋 VM。NY-1：預設阻塞到
/// READY、逾時降級印 `booting`（不自殺）；`--no-wait` 即回 booting。印 `<id> <state> <ip>` 一行。
struct SpawnCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "spawn",
		abstract: "Spawn a disposable VM from a golden alias (daemon)."
	)

	/// golden 別名（非 host 路徑；daemon 解析）。
	@Argument(help: "Golden alias to spawn from.")
	var golden: String

	/// guest 種類（`mac` / `linux`）；未知值於 `run()` 明確擲錯、不預設回 mac。
	@Option(name: .customLong("kind"), help: "Guest kind to spawn: mac or linux.")
	var kind: String = GuestKind.mac.rawValue

	/// 要求 vCPU 數。
	@Option(help: "Virtual CPU count (clamped to host limits).")
	var cpus: Int = 4

	/// 要求記憶體（GiB）。
	@Option(name: .customLong("memory-gib"), help: "Memory in GiB (clamped to host limits).")
	var memoryGiB: Int = 4

	/// 不阻塞、即回 booting（預設阻塞到 READY）。
	@Flag(name: .customLong("no-wait"), help: "Return immediately as booting instead of blocking to READY.")
	var noWait = false

	/// readiness 等待上限（秒）。
	@Option(name: .customLong("readiness-timeout"), help: "Readiness wait ceiling in seconds.")
	var readinessTimeoutSeconds: Int = 180

	func run() async throws {
		guard let guestKind: GuestKind = .init(rawValue: kind) else {
			throw ValidationError("unknown --kind value \"\(kind)\"; expected one of: \(GuestKind.allCases.map(\.rawValue).joined(separator: ", ")).")
		}
		let request: NymphRequest = .spawn(SpawnParams(
			golden: golden,
			kind: guestKind,
			cpus: cpus,
			memoryGiB: memoryGiB,
			wait: !noWait,
			readinessTimeoutSeconds: readinessTimeoutSeconds
		))
		switch try await NymphClientSupport.send(request) {
		case let .spawn(result):
			print("\(result.id) \(result.state.rawValue) \(result.ip ?? "none")")

		case let .toolError(error):
			throw NymphClientSupport.fail(error)

		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
