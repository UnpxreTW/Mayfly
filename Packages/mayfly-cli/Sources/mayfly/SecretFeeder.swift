//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 起一個本機命令、把密碼餵進它的 stdin。
///
/// 只有 stdin 接 pipe：寫入密碼與一個換行後即關閉（命令讀到的就是一行、接著是輸入結束）。
/// stdout 與 stderr 直接沿用這個行程的，命令的輸出原樣流出、不經緩衝。
internal enum SecretFeeder {

	/// 跑命令到結束。
	///
	/// - Parameters:
	///   - command: argv；第一個元素經 `PATH` 找執行檔（交給 `/usr/bin/env`）。
	///   - secret: 要餵的密碼。
	/// - Returns: 命令的結束碼；被訊號終止時為 128 加訊號編號（與 shell 的慣例相同）。
	/// - Throws: 命令起不來時的錯誤。
	internal static func run(_ command: [String], secret: Data) async throws -> Int32 {
		let process: Process = .init()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = command
		let standardInputPipe: Pipe = .init()
		// 命令沒讀 stdin 就先結束時，寫入只回錯誤、不送 SIGPIPE 把這個行程殺掉。
		_ = fcntl(standardInputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		process.standardInput = standardInputPipe
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
			process.terminationHandler = { finished in
				switch finished.terminationReason {
				case .uncaughtSignal:
					continuation.resume(returning: 128 + finished.terminationStatus)
				default:
					continuation.resume(returning: finished.terminationStatus)
				}
			}
			do {
				try process.run()
			} catch {
				process.terminationHandler = nil
				continuation.resume(throwing: error)
				return
			}
			DispatchQueue.global().async {
				// 命令沒讀 stdin 就先結束時寫入會失敗，丟掉即可：結束碼會照實回報。
				try? standardInputPipe.fileHandleForWriting.write(contentsOf: secret + Data([0x0A]))
				try? standardInputPipe.fileHandleForWriting.close()
			}
		}
	}
}
