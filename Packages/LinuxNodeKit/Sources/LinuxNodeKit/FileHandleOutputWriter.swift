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
// BufferedOutputWriter.swift）。

#if arch(arm64)

/// 把 `container.exec` 的輸出邊收邊寫進一個 `FileHandle` 的 ``Writer``。
///
/// 寫入失敗（磁碟滿、對端關閉）時記下第一個錯誤、之後的寫入一律擲同一個錯誤。Containerization
/// 在背景的 IO relay 呼叫 `write(_:)`，擲出的錯誤不保證會傳回等待行程的那一端——命令照樣以
/// 結束碼 0 收場、檔案卻少了一段。所以呼叫端在行程結束後必須自己看 ``firstError``。
internal final class FileHandleOutputWriter: Writer, @unchecked Sendable {

	/// - Parameters:
	///   - handle: 寫入目標。
	///   - closesHandle: ``close()`` 時是否一併關閉 `handle`；轉給 `FileHandle.standardError`
	///     這種不屬於自己的 handle 時傳 `false`。
	internal init(handle: FileHandle, closesHandle: Bool) {
		self.handle = handle
		self.closesHandle = closesHandle
	}

	/// 已寫入的位元組數。
	internal var bytesWritten: Int64 {
		lock.lock()
		defer { lock.unlock() }
		return written
	}

	/// 第一次寫入失敗時的錯誤；`nil`＝至今都寫成功。
	internal var firstError: (any Error)? {
		lock.lock()
		defer { lock.unlock() }
		return failure
	}

	/// 寫一段輸出；先前已失敗過就擲同一個錯誤、不再寫。
	/// - Parameter data: 要寫的位元組。
	/// - Throws: 寫入失敗時的錯誤。
	internal func write(_ data: Data) throws {
		lock.lock()
		defer { lock.unlock() }
		if let failure {
			throw failure
		}
		do {
			try handle.write(contentsOf: data)
			written += Int64(data.count)
		} catch {
			failure = error
			throw error
		}
	}

	/// 關閉；重複呼叫無作用（Containerization 與呼叫端都可能呼叫一次）。
	/// - Throws: 關閉 handle 失敗時的錯誤。
	internal func close() throws {
		lock.lock()
		defer { lock.unlock() }
		guard !closed else { return }
		closed = true
		if closesHandle {
			try handle.close()
		}
	}

	// MARK: Private

	/// 護住下列可變狀態：寫入來自背景的 IO relay。
	private let lock: NSLock = .init()

	/// 寫入目標。
	private let handle: FileHandle

	/// ``close()`` 時是否一併關閉 ``handle``。
	private let closesHandle: Bool

	/// 已寫入的位元組數。
	private var written: Int64 = 0

	/// 第一次寫入失敗時的錯誤。
	private var failure: (any Error)?

	/// 是否已關閉。
	private var closed: Bool = false
}

#endif
