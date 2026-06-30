//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 用 Foundation `Process` 跑真命令的 ``CommandRunner``。stdout / stderr **並行 drain**
/// （各自背景 queue `readDataToEndOfFile`）後才 `waitUntilExit`——避免任一 pipe buffer
/// 填滿造成子行程寫阻塞 / 我方讀阻塞的 deadlock（diskutil apfs list 輸出可達數十 KB）。
/// drain **在 `run()` 成功後**才 dispatch：spawn 失敗（路徑不存在 / 沙箱拒絕 / 資源不足）時
/// Pipe 未被 closure 捕捉、立即釋放關 fd，不留卡死的 drain thread。
public struct SystemCommandRunner: CommandRunner {

	public func run(executable: String, arguments: [String]) async throws -> Data {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
			DispatchQueue.global().async {
				let process: Process = .init()
				process.executableURL = URL(fileURLWithPath: executable)
				process.arguments = arguments
				let stdoutPipe: Pipe = .init()
				let stderrPipe: Pipe = .init()
				process.standardOutput = stdoutPipe
				process.standardError = stderrPipe
				do {
					try process.run()
				} catch {
					// spawn 失敗：Pipe 尚未被任何 drain closure 捕捉，隨即釋放關 fd——不洩漏
					// thread / fd（drain 故意排在 run() 之後才 dispatch）。
					continuation.resume(throwing: error)
					return
				}
				// spawn 成功後才 dispatch 並行 drain（仍保留防 pipe-buffer-fill deadlock）。
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
				process.waitUntilExit()
				group.wait()
				if process.terminationStatus == 0 {
					continuation.resume(returning: stdout.get())
				} else {
					continuation.resume(throwing: GuestVolumeMounterError.commandFailed(
						executable: executable,
						status: process.terminationStatus,
						stderr: String(bytes: stderr.get(), encoding: .utf8) ?? ""
					))
				}
			}
		}
	}

	public init() {}

	/// 跨 queue 安全累積一段 `Data`（drain task 寫、主流程讀，`DispatchGroup` 提供
	/// happens-before）。
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
