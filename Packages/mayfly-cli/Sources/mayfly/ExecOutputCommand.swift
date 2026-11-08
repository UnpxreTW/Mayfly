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

/// `mayfly exec-output <exec-id>`（daemon client）：取背景 exec 目前的輸出。
///
/// 輸出面與 `execute` 相同：遠端 stdout／stderr 各自原樣轉出，命令已自行結束時把它的結束碼
/// 當本行程退出碼；逾時、SSH 傳輸失敗、被取消記一行錯誤並以 1 退出。還在跑時退出碼為 0、
/// 另記一行 notice——要拿結束碼的呼叫端帶 `--wait`。
///
/// 輸出是 daemon 保留的那一段：過長時開頭已被丟掉，`--tail-bytes` 可再只取最後一段；不是全文
/// 時記一行 notice 說明哪條串流被截。
internal struct ExecOutputCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "exec-output",
		abstract: "Show the output of a background exec (daemon)."
	)

	/// 背景 exec 的 id（`execute --detach` 印出的那一行）。
	@Argument(help: "Background exec id printed by `execute --detach`.")
	internal var execID: String

	/// 每條串流只取最後這麼多 bytes。
	@Option(name: .customLong("tail-bytes"), help: "Return only the last N bytes of each stream.")
	internal var tailBytes: Int?

	/// 輪詢到命令結束為止，再以它的結束碼退出。
	@Flag(name: .customLong("wait"), help: "Poll until the command ends, then exit with its exit code.")
	internal var wait: Bool = false

	/// `--wait` 兩輪之間的間隔（秒）。
	@Option(name: .customLong("poll-interval"), help: "Seconds between polls with --wait.")
	internal var pollIntervalSeconds: Int = 1

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 擋下負的 `--tail-bytes` 與小於 1 秒的 `--poll-interval`。
	internal func validate() throws {
		if let tailBytes: Int, tailBytes < 0 {
			throw ValidationError("--tail-bytes must not be negative.")
		}
		guard pollIntervalSeconds >= 1 else {
			throw ValidationError("--poll-interval must be at least 1 second.")
		}
	}

	/// 進入點：見型別說明。
	internal func run() async throws {
		let response: NymphResponse
		if wait {
			let interval: Duration = .seconds(pollIntervalSeconds)
			response = try await DetachedExecSupport.waitUntilEnded(
				execID: execID,
				tailBytes: tailBytes,
				pause: { try await Task.sleep(for: interval) },
				send: { try await NymphClientSupport.send($0) }
			)
		} else {
			let request: NymphRequest = .execOutput(ExecOutputParams(execID: execID, tailBytes: tailBytes))
			response = try await NymphClientSupport.send(request)
		}
		switch response {
		case let .execOutput(result):
			FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
			FileHandle.standardError.write(Data(result.standardError.utf8))
			if let notice: String = DetachedExecSupport.truncationNotice(for: result) {
				CommandOutput.logger.log(level: .notice, "\(notice)")
			}
			let ending: (exit: Int32, error: String?)? = DetachedExecSupport.termination(of: result, execID: execID)
			guard let ending else {
				CommandOutput.logger.log(level: .notice, "exec \(execID) is still running")
				return
			}
			if let message: String = ending.error {
				CommandOutput.logger.log(level: .error, "\(message)")
			}
			throw ExitCode(ending.exit)
		case let .toolError(error):
			throw DetachedExecSupport.fail(error)
		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
