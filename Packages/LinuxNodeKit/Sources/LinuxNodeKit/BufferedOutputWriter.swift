//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation

// Writer 是 Containerization 的 IO 協定，隨真容器 API 一起 arch gate（比照
// LinuxGuestControl.swift）。

#if arch(arm64)

/// 收集 `container.exec` stdout / stderr 的記憶體內 ``Writer``。NSLock 護寫入——
/// Containerization 可能在背景 IO relay 執行緒呼叫 `write(_:)`，非單一呼叫端序列化。
final class BufferedOutputWriter: Writer, @unchecked Sendable {

	var data: Data {
		lock.lock()
		defer { lock.unlock() }
		return storage
	}

	func write(_ data: Data) throws {
		lock.lock()
		storage.append(data)
		lock.unlock()
	}

	func close() throws {}

	private let lock: NSLock = .init()

	private var storage: Data = .init()
}

#endif