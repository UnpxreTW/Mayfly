//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 用 Foundation `Process` 跑真行程的 ``ProcessRunner``。
///
/// stdout / stderr **並行 drain**（各自背景 queue `readDataToEndOfFile`）避免任一 pipe
/// buffer 填滿造成子行程寫阻塞 / 我方讀阻塞的 deadlock（沿用 ``SystemCommandRunner``
/// 的合約）。`standardInput` 於 spawn 後寫入並關閉、nil 則立即關端送 EOF——否則 ssh
/// 會空等我方 stdin、命令永不返回。`timeout` 非 nil 時掛 wall-clock 監看：逾時
/// `terminate()`（SIGTERM）、收乾殘餘輸出後擲 ``ProcessRunnerError/timedOut(_:)``；SSH
/// 自身的 `ConnectTimeout` 由 ``MacGuestExec`` 另外下（連線層），本層是整體壁鐘上限。
public struct SystemProcessRunner: ProcessRunner {

	public func run(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		timeout: Duration?
	) async throws -> ProcessRunResult {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessRunResult, any Error>) in
			DispatchQueue.global().async {
				let process: Process = .init()
				process.executableURL = URL(fileURLWithPath: executable)
				process.arguments = arguments
				let stdoutPipe: Pipe = .init()
				let stderrPipe: Pipe = .init()
				let stdinPipe: Pipe = .init()
				process.standardOutput = stdoutPipe
				process.standardError = stderrPipe
				process.standardInput = stdinPipe
				do {
					try process.run()
				} catch {
					// spawn 失敗：Pipe 尚未被 drain closure 捕捉，隨即釋放關 fd、不洩漏。
					continuation.resume(throwing: error)
					return
				}
				// stdin：有內容就寫、一律關寫端送 EOF（否則 ssh 空等輸入、命令不返回）。
				if let standardInput {
					stdinPipe.fileHandleForWriting.write(standardInput)
				}
				try? stdinPipe.fileHandleForWriting.close()
				let stdout: DataBox = .init()
				let stderr: DataBox = .init()
				let group: DispatchGroup = .init()
				group.enter()
				DispatchQueue.global().async {
					stdout.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
					group.leave()
				}
				group.enter()
				DispatchQueue.global().async {
					stderr.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
					group.leave()
				}
				// 壁鐘上限：drain group 隨行程關 stdout / stderr（即退出）而完成；逾時
				// terminate、待 drain 收乾、reap 後以 timedOut 收斂。無 timeout 則無界等。
				if let timeout, group.wait(timeout: .now() + Self.seconds(timeout)) == .timedOut {
					process.terminate()
					group.wait()
					process.waitUntilExit()
					continuation.resume(throwing: ProcessRunnerError.timedOut(timeout))
					return
				}
				group.wait()
				process.waitUntilExit()
				continuation.resume(returning: ProcessRunResult(
					standardOutput: stdout.get(),
					standardError: stderr.get(),
					exitCode: process.terminationStatus
				))
			}
		}
	}

	public init() {}

	// MARK: Private

	/// `Duration` → 秒（Double），供 `DispatchTime` 的截止時間運算。attoseconds 併入
	/// 小數秒；不做飽和夾制——timeout 由呼叫端給的合理正值。
	private static func seconds(_ duration: Duration) -> Double {
		let components = duration.components
		return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
	}

	/// 跨 queue 安全累積一段 `Data`（drain task 寫、主流程讀，`DispatchGroup` 提供
	/// happens-before）。沿用 ``SystemCommandRunner`` 的同名封套。
	private final class DataBox: @unchecked Sendable {

		func set(_ data: Data) {
			lock.lock()
			defer { lock.unlock() }
			value = data
		}

		func get() -> Data {
			lock.lock()
			defer { lock.unlock() }
			return value
		}

		private let lock: NSLock = .init()

		private var value: Data = .init()
	}
}

/// ``SystemProcessRunner`` 的 ``ProcessLauncher`` 面：用 Foundation `Process` 起真行程、
/// 以 `readabilityHandler` 逐段讀 stdout / stderr。
///
/// 兩條 pipe 各自由 Foundation 的背景讀取驅動、互不阻塞，任一條 buffer 滿不會卡住另一條
/// （與 ``SystemProcessRunner/run(executable:arguments:standardInput:timeout:)`` 的並行 drain
/// 同一個理由）。stdin 在背景 queue 寫完即關——寫入量大於 pipe buffer 而對方還沒讀時，
/// 啟動這一步不會被卡住。
extension SystemProcessRunner: ProcessLauncher {

	/// 啟動行程、掛上兩條串流的逐段讀取，回已啟動的行程（語意見 ``ProcessLauncher``）。
	public func launch(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) throws -> any LaunchedProcess {
		let process: Process = .init()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		let stdoutPipe: Pipe = .init()
		let stderrPipe: Pipe = .init()
		let stdinPipe: Pipe = .init()
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe
		process.standardInput = stdinPipe
		// 三件事都到齊才算結束：行程退出、兩條 pipe 各讀到 EOF。只等退出的話，最後一段輸出
		// 可能還在 pipe 裡沒進緩衝。
		let group: DispatchGroup = .init()
		group.enter()
		group.enter()
		group.enter()
		SystemProcessRunner.drain(stdoutPipe, into: standardOutput, group: group)
		SystemProcessRunner.drain(stderrPipe, into: standardError, group: group)
		process.terminationHandler = { _ in group.leave() }
		do {
			try process.run()
		} catch {
			stdoutPipe.fileHandleForReading.readabilityHandler = nil
			stderrPipe.fileHandleForReading.readabilityHandler = nil
			throw error
		}
		DispatchQueue.global().async {
			if let standardInput {
				// 對方先結束（例如連線失敗）時寫入會失敗，丟掉即可：結束碼與 stderr 會說明原因。
				try? stdinPipe.fileHandleForWriting.write(contentsOf: standardInput)
			}
			// 關寫端失敗只會發生在對方已結束、pipe 已斷時，此時沒有需要送 EOF 的對象。
			try? stdinPipe.fileHandleForWriting.close()
		}
		return SystemLaunchedProcess(process: process, group: group)
	}

	/// 掛 `readabilityHandler`：非空就寫進緩衝；讀到空資料＝EOF，拆掉 handler 並離開 group。
	/// - Parameters:
	///   - pipe: 要讀的 pipe。
	///   - buffer: 寫入的緩衝。
	///   - group: 讀到 EOF 時離開的會合點。
	private static func drain(_ pipe: Pipe, into buffer: OutputTailBuffer, group: DispatchGroup) {
		pipe.fileHandleForReading.readabilityHandler = { handle in
			let chunk: Data = handle.availableData
			if chunk.isEmpty {
				handle.readabilityHandler = nil
				group.leave()
			} else {
				buffer.append(chunk)
			}
		}
	}
}
