//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import NymphKit

/// `mayfly execute <id> <cmd…>`（daemon client，別名 `exec`）：在 session 內經 SSH 跑命令。
/// **exit code 是資料**——把遠端結束碼原樣當本行程退出碼（stdout / stderr 各自轉出）；只有
/// 「無法把命令送進 VM」（no such id / 未 ready / 傳輸失敗 / 逾時）才走 tool-error（stderr +
/// exit 1）。
///
/// 選項須置於 id 之前（命令陣列 passthrough 捕獲其後全部 token）：
/// `mayfly execute --timeout 30 <id> ls -la`。
struct ExecuteCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "execute",
		abstract: "Run a command inside a session over SSH (daemon).",
		aliases: ["exec"]
	)

	/// 目標 session id。
	@Argument(help: "Session id.")
	var id: String

	/// 遠端命令 argv（含選項 token 一併捕獲）。
	@Argument(parsing: .captureForPassthrough, help: "Command and arguments to run remotely.")
	var command: [String] = []

	/// 整體逾時（秒）。
	@Option(name: .customLong("timeout"), help: "Overall timeout in seconds.")
	var timeoutSeconds: Int?

	/// 遠端工作目錄。
	@Option(name: .customLong("cwd"), help: "Remote working directory.")
	var workingDirectory: String?

	/// 額外環境變數（`KEY=VALUE`、可重複）。
	@Option(name: .customLong("env"), help: "Environment variable KEY=VALUE (repeatable).")
	var environmentPairs: [String] = []

	/// 把本行程 stdin 轉送為遠端命令 stdin。
	@Flag(name: .customLong("stdin"), help: "Forward this process's stdin to the remote command.")
	var forwardStdin = false

	func run() async throws {
		guard !command.isEmpty else {
			throw ValidationError("execute requires a command to run.")
		}
		let environment: [String: String] = try NymphClientSupport.parseEnvironment(environmentPairs)
		let standardInput: String? = forwardStdin
			? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
			: nil
		let request: NymphRequest = .execute(ExecuteParams(
			id: id,
			command: command,
			timeoutSeconds: timeoutSeconds,
			standardInput: standardInput,
			workingDirectory: workingDirectory,
			environment: environment
		))
		switch try await NymphClientSupport.send(request) {
		case let .execute(result):
			FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
			FileHandle.standardError.write(Data(result.standardError.utf8))
			throw ExitCode(result.exit)

		case let .toolError(error):
			throw NymphClientSupport.fail(error)

		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
