//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

extension MacGuestExec {

	// MARK: Public

	/// 以 nymph 私鑰 SSH 進 `ipAddress` 啟動 `command`、**不等它結束**：stdout / stderr 逐段
	/// 寫進呼叫端給的緩衝，回一個可等待、可取消的 ``MacGuestExecHandle``。
	///
	/// 遠端命令前多帶一段：把登入 shell 的行程編號寫進 guest 的暫存檔。sshd 在無 pty 的連線上
	/// 讓這個 shell 開新 session（OpenSSH `session.c` 的 `do_exec_no_pty` 於子行程呼叫
	/// `setsid()`），它因此是整棵行程樹的行程群組首領；終止時對這個群組送訊號，命令自己再開的
	/// 子行程一併收得到（命令自己 `setsid` 出去的除外）。命令的 argv、cwd、env 與 ``run(_:onHost:timeout:standardInput:workingDirectory:environment:)``
	/// 同一套跳脫。
	///
	/// - Parameters:
	///   - command: 遠端命令 argv。
	///   - ipAddress: guest 現時 IP。
	///   - standardInput: 餵給遠端命令 stdin 的文字；nil＝無輸入。
	///   - workingDirectory: 遠端執行前 `cd` 的目錄；nil＝登入預設目錄。
	///   - environment: 遠端命令的額外環境變數。
	///   - standardOutput: stdout 的落點。
	///   - standardError: stderr 的落點。
	/// - Returns: 執行中的命令。
	/// - Throws: ``MacGuestExecError/launchFailed(_:)``（ssh 起不來）。
	public func start(
		_ command: [String],
		onHost ipAddress: String,
		standardInput: String? = nil,
		workingDirectory: String? = nil,
		environment: [String: String] = [:],
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) throws -> MacGuestExecHandle {
		let groupFile: String = MacGuestExec.groupFilePath(token: UUID().uuidString.lowercased())
		let script: String = MacGuestExec.recordGroupPrefix(groupFile: groupFile) + MacGuestExec.remoteCommand(
			command: command,
			workingDirectory: workingDirectory,
			environment: environment
		)
		let process: any LaunchedProcess
		do {
			process = try launcher.launch(
				executable: sshExecutable,
				arguments: sshArguments(ipAddress: ipAddress, remoteScript: script, timeout: MacGuestExec.connectTimeout),
				standardInput: standardInput.map { Data($0.utf8) },
				standardOutput: standardOutput,
				standardError: standardError
			)
		} catch {
			throw MacGuestExecError.launchFailed(String(describing: error))
		}
		return MacGuestExecHandle(
			process: process,
			standardError: standardError,
			terminateRemote: { [self] in
				// 終止這一趟失敗（guest 已連不上等）不擋收尾：接著照樣收本機 ssh。
				_ = try? await runner.run(
					executable: sshExecutable,
					arguments: sshArguments(
						ipAddress: ipAddress,
						remoteScript: MacGuestExec.killGroupScript(groupFile: groupFile),
						timeout: MacGuestExec.terminationTimeout
					),
					standardInput: nil,
					timeout: MacGuestExec.terminationTimeout
				)
			}
		)
	}

	// MARK: Internal

	/// 終止流程那一趟 ssh 的上限：連線＋SIGTERM 後的寬限＋SIGKILL。
	internal static let terminationTimeout: Duration = .seconds(15)

	/// 群組檔在 guest 內的路徑。
	/// - Parameter token: 這次執行的唯一標記。
	internal static func groupFilePath(token: String) -> String {
		"/tmp/mayfly-exec-\(token).pgid"
	}

	/// 寫群組檔的前綴：寫不進去也照跑命令（只是終止時收不到子行程），錯誤訊息不混進 stderr。
	/// 寫完再看一次取消標記——終止那一趟若搶在群組檔寫入前就到，命令在這裡自行結束、不會
	/// 在取消之後才開始跑。
	/// - Parameter groupFile: 群組檔路徑。
	internal static func recordGroupPrefix(groupFile: String) -> String {
		let file: String = shellQuote(groupFile)
		let marker: String = shellQuote(groupFile + ".cancel")
		return "{ echo $$ > \(file); } 2>/dev/null; [ -e \(marker) ] && exit 143; "
	}

	/// 終止那一趟的遠端腳本：先立取消標記，再對群組送 SIGTERM、寬限 2 秒後補 SIGKILL，刪群組檔。
	/// 群組檔還不在或還是空的（命令還沒寫入）時不送訊號，由命令那端看到標記自行結束；標記不刪，晚到的
	/// 命令照樣看得到。
	/// - Parameter groupFile: 群組檔路徑。
	internal static func killGroupScript(groupFile: String) -> String {
		let file: String = shellQuote(groupFile)
		let marker: String = shellQuote(groupFile + ".cancel")
		return "touch \(marker) 2>/dev/null; pg=$(cat \(file) 2>/dev/null) || exit 0; [ -n \"$pg\" ] || exit 0; "
			+ "kill -TERM -- \"-$pg\" 2>/dev/null; sleep 2; kill -KILL -- \"-$pg\" 2>/dev/null; "
			+ "rm -f \(file); exit 0"
	}
}
