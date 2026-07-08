//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation

/// 記錄被下的命令、依 handler 回應的假 ``ProcessRunner``——驗 argv 構造 / 結果映射、
/// 不碰真行程。handler 回 `.success(ProcessRunResult)`（含指定結束碼、模擬遠端命令
/// 退出）或 `.failure`（模擬逾時 ``ProcessRunnerError/timedOut(_:)`` / spawn 失敗）。
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {

	init(_ handler: @escaping @Sendable (String, [String], Data?) -> Result<ProcessRunResult, any Error>) {
		self.handler = handler
	}

	/// 一次被記錄的命令。
	struct Call {

		let executable: String

		let arguments: [String]

		let standardInput: Data?

		let timeout: Duration?
	}

	var calls: [Call] {
		lock.withLock { recorded }
	}

	func run(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		timeout: Duration?
	) async throws -> ProcessRunResult {
		lock.withLock {
			recorded.append(Call(
				executable: executable,
				arguments: arguments,
				standardInput: standardInput,
				timeout: timeout
			))
		}
		switch handler(executable, arguments, standardInput) {
		case let .success(result):
			return result
		case let .failure(error):
			throw error
		}
	}

	private let handler: @Sendable (String, [String], Data?) -> Result<ProcessRunResult, any Error>

	private let lock: NSLock = .init()

	private var recorded: [Call] = []
}
