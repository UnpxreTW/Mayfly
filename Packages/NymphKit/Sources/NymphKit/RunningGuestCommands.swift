//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - RunningGuestCommands

/// 一台 guest 上進行中的命令登記：啟動時登記、結束時自行移除。
internal final class RunningGuestCommands: @unchecked Sendable {

	/// 登記一條命令；它結束時自動移除。
	/// - Parameter execution: 剛啟動的命令。
	internal func track(_ execution: any GuestExecution) {
		let key: UUID = .init()
		lock.withLock { entries[key] = execution }
		Task { [weak self] in
			_ = await execution.wait(timeout: nil)
			self?.remove(key)
		}
	}

	/// 目前登記中的命令。
	/// - Returns: 進行中的命令（快照）。
	internal func current() -> [any GuestExecution] {
		lock.withLock { Array(entries.values) }
	}

	/// 護住 ``entries``。
	private let lock: NSLock = .init()

	/// 登記中的命令。
	private var entries: [UUID: any GuestExecution] = [:]

	/// 移除一筆登記。
	/// - Parameter key: 登記時配的鍵。
	private func remove(_ key: UUID) {
		lock.withLock { entries[key] = nil }
	}
}
