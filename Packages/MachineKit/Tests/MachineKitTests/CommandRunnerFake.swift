//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation

/// 記錄被下的命令、依 handler 回應的假 ``CommandRunner``——驗命令構造 / 解析、不碰真磁碟。
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {

	init(_ handler: @escaping @Sendable (String, [String]) -> Result<Data, any Error>) {
		self.handler = handler
	}

	/// 一次被記錄的命令。
	struct Call {

		let executable: String

		let arguments: [String]
	}

	var calls: [Call] {
		lock.withLock { recorded }
	}

	func run(executable: String, arguments: [String]) async throws -> Data {
		lock.withLock {
			recorded.append(Call(executable: executable, arguments: arguments))
		}
		switch handler(executable, arguments) {
		case let .success(data):
			return data
		case let .failure(error):
			throw error
		}
	}

	private let handler: @Sendable (String, [String]) -> Result<Data, any Error>

	private let lock: NSLock = .init()

	private var recorded: [Call] = []
}
