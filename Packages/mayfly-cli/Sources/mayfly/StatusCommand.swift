//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit

import ArgumentParser

/// `mayfly status <id>`（daemon client）：查單一 session 狀態（含 stop_reason）。no-such-id
/// 走 tool-error（stderr + exit 1）。
struct StatusCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "status",
		abstract: "Show a session's status (daemon)."
	)

	/// 目標 session id。
	@Argument(help: "Session id.")
	var id: String

	func run() async throws {
		switch try await NymphClientSupport.send(.status(StatusParams(id: id))) {
		case let .status(result):
			let session: SessionSummary = result.summary
			CommandOutput.write("id: \(session.id)")
			CommandOutput.write("state: \(session.state.rawValue)")
			CommandOutput.write("ip: \(session.ip ?? "none")")
			CommandOutput.write("golden: \(session.golden)")
			CommandOutput.write("cpus: \(session.cpus)")
			CommandOutput.write("memory_gib: \(session.memoryGiB)")
			CommandOutput.write("uptime_s: \(session.uptimeSeconds)")
			if let reason = result.stopReason {
				CommandOutput.write("stop_reason: \(reason)")
			}

		case let .toolError(error):
			throw NymphClientSupport.fail(error)

		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
