//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import NymphKit

/// `mayfly exec-cancel <exec-id>`（daemon client）：取消背景 exec，等它收尾後印最終狀態。
///
/// stdout 是 `key: value` 行（同 `status`）：`state:` 一行；命令在取消送達前已自行結束時另有
/// `exit:` 一行。取消成功退出碼為 0。命令早已結束（`exec_not_running`）或查無此 id
/// （`exec_not_found`）記一行錯誤、退出碼 1。輸出本身不在這裡印——取消後紀錄仍在，
/// 照樣以 `exec-output` 取。
internal struct ExecCancelCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "exec-cancel",
		abstract: "Cancel a background exec and show its final state (daemon)."
	)

	/// 背景 exec 的 id（`execute --detach` 印出的那一行）。
	@Argument(help: "Background exec id printed by `execute --detach`.")
	internal var execID: String

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 進入點：見型別說明。
	internal func run() async throws {
		switch try await NymphClientSupport.send(.execCancel(ExecCancelParams(execID: execID))) {
		case let .execCancel(result):
			CommandOutput.write("state: \(result.state.rawValue)")
			if let exit: Int32 = result.exit {
				CommandOutput.write("exit: \(exit)")
			}
		case let .toolError(error):
			throw DetachedExecSupport.fail(error)
		default:
			throw NymphClientSupport.unexpectedResponse()
		}
	}
}
