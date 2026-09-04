//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit

import ArgumentParser

/// `mayfly list`（daemon client，別名 `ps`）：列出 session（tab 分隔表；不含 host 路徑）。
/// 預設只列活的、`--all` 含已 stopped 未回收者。空表為正常。
struct ListCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "list",
		abstract: "List sessions (daemon).",
		aliases: ["ps"]
	)

	/// 含已 stopped 未回收者。
	@Flag(help: "Include stopped, unreaped sessions.")
	var all = false

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	func run() async throws {
		switch try await NymphClientSupport.send(.list(ListParams(all: all))) {
		case let .list(result):
			CommandOutput.write("ID\tSTATE\tIP\tGOLDEN\tCPUS\tMEM_GIB\tUPTIME_S")
			for session in result.sessions {
				let columns: [String] = [
					session.id,
					session.state.rawValue,
					session.ip ?? "-",
					session.golden,
					"\(session.cpus)",
					"\(session.memoryGiB)",
					"\(session.uptimeSeconds)"
				]
				CommandOutput.write(columns.joined(separator: "\t"))
			}

		case let .toolError(error):
			throw NymphClientSupport.fail(error)

		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
