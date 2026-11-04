//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``SystemProcessRunner`` 啟動的行程。
internal final class SystemLaunchedProcess: LaunchedProcess, @unchecked Sendable {

	// MARK: Internal

	/// - Parameters:
	///   - process: 已設好 terminationHandler 的行程。
	///   - group: 退出＋兩條 EOF 的會合點。
	internal init(process: Process, group: DispatchGroup) {
		self.process = process
		self.group = group
	}

	/// 見 ``LaunchedProcess/waitForExit()``。
	internal func waitForExit() async -> Int32 {
		await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
			group.notify(queue: .global()) { [process] in
				continuation.resume(returning: process.terminationStatus)
			}
		}
	}

	/// 見 ``LaunchedProcess/terminate()``。
	internal func terminate() {
		// 已結束的行程不再送訊號：pid 可能已被系統重新分配給別的行程。
		guard process.isRunning else { return }
		process.terminate()
	}

	// MARK: Private

	/// 底層行程。
	private let process: Process

	/// 退出＋兩條 EOF 的會合點。
	private let group: DispatchGroup
}
