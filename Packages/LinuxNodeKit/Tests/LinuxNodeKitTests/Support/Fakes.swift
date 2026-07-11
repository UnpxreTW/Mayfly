//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LinuxNodeKit

/// 極簡上鎖封套——fake 需在跨隔離（`async` 呼叫）間累積呼叫紀錄，用 NSLock 護一份可變
/// 值即可，避免測試依賴具體並行原語（同 NymphKitTests/Support/Fakes.swift 的既有模式）。
final class Locked<Value>: @unchecked Sendable {

	init(_ value: Value) {
		self.value = value
	}

	@discardableResult
	func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&value)
	}

	var current: Value {
		withLock { $0 }
	}

	private let lock: NSLock = .init()

	private var value: Value
}

/// 假 ``KernelArchiveFetching``：記錄收到的 archive / destination，可配成功寫入
/// 佔位檔或擲固定錯誤——把 ``LinuxKernelProvisioner`` 的 fetch-on-demand 編排與真連網
/// / 真 tar 解壓隔開來測。
final class FakeKernelArchiveFetcher: KernelArchiveFetching, @unchecked Sendable {

	init(failure: (any Error)? = nil, writtenContents: String = "fake-kernel-bytes") {
		self.failure = failure
		self.writtenContents = writtenContents
	}

	struct FetchCall {

		let archive: LinuxKernelArchive

		let destination: URL
	}

	let calls: Locked<[FetchCall]> = .init([])

	func fetch(_ archive: LinuxKernelArchive, to destination: URL) async throws {
		calls.withLock { $0.append(FetchCall(archive: archive, destination: destination)) }
		if let failure {
			throw failure
		}
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(writtenContents.utf8).write(to: destination)
	}

	private let failure: (any Error)?

	private let writtenContents: String
}
