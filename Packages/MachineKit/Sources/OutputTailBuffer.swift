//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一條輸出串流（stdout 或 stderr）的有上限尾端緩衝：行程跑著時逐段寫入、任何時候都可取
/// 目前的內容。
///
/// 超過上限時丟頭留尾——執行中要看的是最近的輸出，開頭那段在長命令裡最沒用。被丟掉過就把
/// ``Snapshot/truncated`` 標成 true（之後不會再變回 false），讀取端據此知道拿到的不是全文。
/// 截斷點對齊 UTF-8 字元邊界：留下的第一個 byte 不會是多 byte 字元的後續 byte，解碼出來的
/// 文字開頭不會多一個替代字元。
///
/// 寫入可能來自背景 IO 執行緒、讀取來自別的隔離域，內部以 `NSLock` 護住；鎖不跨任何 `await`。
public final class OutputTailBuffer: @unchecked Sendable {

	// MARK: Public

	/// 某一時刻的緩衝內容。
	public struct Snapshot: Sendable, Equatable {

		/// 目前保留的原始 bytes（最多上限長度）。
		public let data: Data

		/// 是否曾因超過上限而丟掉開頭。
		public let truncated: Bool

		/// 最後一次寫入非空資料的時間；從未寫入為 nil。
		public let lastWriteAt: Date?

		/// - Parameters:
		///   - data: 保留的 bytes。
		///   - truncated: 是否曾丟掉開頭。
		///   - lastWriteAt: 最後寫入時間。
		public init(data: Data, truncated: Bool, lastWriteAt: Date?) {
			self.data = data
			self.truncated = truncated
			self.lastWriteAt = lastWriteAt
		}

		/// 以 UTF-8 解碼的文字（無法解的 byte 以替代字元帶過）。
		public var text: String {
			String(decoding: data, as: UTF8.self)
		}
	}

	/// 預設上限：1 MiB。
	public static let defaultCapacity: Int = 1 << 20

	/// - Parameters:
	///   - capacity: 保留的 byte 上限；小於 1 一律當 1。
	///   - clock: 時間源（``Snapshot/lastWriteAt`` 用；測試注入固定值）。
	public init(
		capacity: Int = OutputTailBuffer.defaultCapacity,
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.capacity = max(1, capacity)
		self.clock = clock
	}

	/// 寫入一段資料。空資料不算一次寫入（不更新 ``Snapshot/lastWriteAt``）。
	/// - Parameter chunk: 行程剛吐出的 bytes。
	public func append(_ chunk: Data) {
		guard !chunk.isEmpty else { return }
		let now: Date = clock()
		lock.lock()
		defer { lock.unlock() }
		storage.append(chunk)
		lastWriteAt = now
		guard storage.count > capacity else { return }
		var start: Int = storage.count - capacity
		while start < storage.count, OutputTailBuffer.isContinuationByte(storage[storage.startIndex + start]) {
			start += 1
		}
		storage = Data(storage.suffix(from: storage.startIndex + start))
		truncated = true
	}

	/// 取目前的內容。
	/// - Returns: 當下的 bytes、截斷旗標與最後寫入時間。
	public func snapshot() -> Snapshot {
		lock.lock()
		defer { lock.unlock() }
		return Snapshot(data: storage, truncated: truncated, lastWriteAt: lastWriteAt)
	}

	// MARK: Private

	/// byte 上限。
	private let capacity: Int

	/// 時間源。
	private let clock: @Sendable () -> Date

	/// 護住下列可變狀態。
	private let lock: NSLock = .init()

	/// 目前保留的 bytes。
	private var storage: Data = .init()

	/// 是否曾丟掉開頭。
	private var truncated: Bool = false

	/// 最後一次寫入非空資料的時間。
	private var lastWriteAt: Date?

	/// UTF-8 後續 byte（`10xxxxxx`）。
	private static func isContinuationByte(_ byte: UInt8) -> Bool {
		byte & 0b1100_0000 == 0b1000_0000
	}
}
