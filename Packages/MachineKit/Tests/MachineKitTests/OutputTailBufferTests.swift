//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation
import Testing

// MARK: - OutputTailBufferTests

private final class OutputTailBufferTests {

	/// 未達上限：全數保留、不標截斷。
	@Test
	private func `keeps everything below capacity`() {
		let buffer: OutputTailBuffer = .init(capacity: 16)
		buffer.append(Data("abc".utf8))
		buffer.append(Data("def".utf8))
		let snapshot: OutputTailBuffer.Snapshot = buffer.snapshot()
		#expect(snapshot.text == "abcdef")
		#expect(snapshot.truncated == false)
	}

	/// 超過上限：丟頭留尾、標截斷，之後再寫也維持截斷。
	@Test
	private func `drops head beyond capacity`() {
		let buffer: OutputTailBuffer = .init(capacity: 4)
		buffer.append(Data("abcdef".utf8))
		#expect(buffer.snapshot().text == "cdef")
		#expect(buffer.snapshot().truncated)
		buffer.append(Data("g".utf8))
		#expect(buffer.snapshot().text == "defg")
		#expect(buffer.snapshot().truncated)
	}

	/// 截斷點落在多 byte 字元中間時往後挪到字元邊界：留下的開頭不是後續 byte、解碼無替代字元。
	@Test
	private func `cuts on utf8 boundary`() {
		// 「中」「文」各 3 byte；上限 4 會切在「中」的第 3 byte 之前。
		let buffer: OutputTailBuffer = .init(capacity: 4)
		buffer.append(Data("中文".utf8))
		let snapshot: OutputTailBuffer.Snapshot = buffer.snapshot()
		#expect(snapshot.text == "文")
		#expect(snapshot.data.count == 3)
		#expect(!snapshot.text.unicodeScalars.contains { $0.value == 0xFFFD })
	}

	/// 空資料不算寫入：不更新最後寫入時間。
	@Test
	private func `empty append does not touch last write time`() {
		let stamps: [Date] = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)]
		let index: Locked<Int> = .init(0)
		let buffer: OutputTailBuffer = .init(capacity: 8) {
			index.withLock { value in
				defer { value += 1 }
				return stamps[value]
			}
		}
		#expect(buffer.snapshot().lastWriteAt == nil)
		buffer.append(Data())
		#expect(buffer.snapshot().lastWriteAt == nil)
		buffer.append(Data("a".utf8))
		#expect(buffer.snapshot().lastWriteAt == stamps[0])
		buffer.append(Data("b".utf8))
		#expect(buffer.snapshot().lastWriteAt == stamps[1])
	}
}

// MARK: - Locked

/// 測試用的上鎖封套（clock closure 需在 `@Sendable` 內累加）。
private final class Locked<Value>: @unchecked Sendable {

	init(_ value: Value) {
		self.value = value
	}

	func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&value)
	}

	private let lock: NSLock = .init()

	private var value: Value
}
