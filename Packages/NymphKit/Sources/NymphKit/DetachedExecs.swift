//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

/// 背景 exec 登記簿：紀錄的登記、終局、淘汰與對外輸出的組裝。
///
/// 活在 ``SessionStore``（actor）內、不跨隔離；佔位席與事件紀錄仍由 store 負責。已結束的紀錄最多
/// 保留 ``finishedLimit`` 筆，超過先淘汰最早結束的；還在跑的不淘汰。
internal struct DetachedExecs {

	// MARK: Internal

	/// 一筆背景 exec。
	internal struct Record {

		/// 所屬 session。
		internal let sessionID: String

		/// 執行中的命令。
		internal let execution: any GuestExecution

		/// stdout 緩衝。
		internal let standardOutput: OutputTailBuffer

		/// stderr 緩衝。
		internal let standardError: OutputTailBuffer

		/// 量測脈絡（操作紀錄關閉時為 nil）；結束時發事件。
		internal let trace: SessionLogTrace?

		/// 終局；還在跑為 nil。
		internal var outcome: MacGuestExecOutcome?

		/// 結束時間。
		internal var endedAt: Date?
	}

	/// 已結束的紀錄最多保留幾筆。
	internal static let finishedLimit: Int = 256

	/// 組對外輸出。
	/// - Parameters:
	///   - record: 紀錄。
	///   - tailBytes: 每條串流只取最後這麼多 bytes；nil＝全部。
	/// - Returns: 輸出與狀態。
	internal static func output(of record: Record, tailBytes: Int?) -> ExecOutputResult {
		let standardOutput: OutputTailBuffer.Snapshot = record.standardOutput.snapshot()
		let standardError: OutputTailBuffer.Snapshot = record.standardError.snapshot()
		let outputTail: (text: String, cut: Bool) = tail(of: standardOutput.data, limit: tailBytes)
		let errorTail: (text: String, cut: Bool) = tail(of: standardError.data, limit: tailBytes)
		var exitCode: Int32?
		if case let .exited(code) = record.outcome {
			exitCode = code
		}
		return ExecOutputResult(
			state: state(of: record.outcome),
			standardOutput: outputTail.text,
			standardError: errorTail.text,
			standardOutputTruncated: standardOutput.truncated || outputTail.cut,
			standardErrorTruncated: standardError.truncated || errorTail.cut,
			lastOutputAt: [standardOutput.lastWriteAt, standardError.lastWriteAt].compactMap(\.self).max(),
			exit: exitCode,
			endedAt: record.endedAt
		)
	}

	/// 查一筆紀錄。
	/// - Parameter execID: 背景 exec 的 id。
	internal subscript(execID: String) -> Record? {
		records[execID]
	}

	/// 登記一筆新紀錄，配一個未撞號的 id（`exec-` + 8 hex）。
	/// - Parameter record: 剛啟動的命令。
	/// - Returns: 配給它的 id。
	internal mutating func insert(_ record: Record) -> String {
		var execID: String = DetachedExecs.randomID()
		while records[execID] != nil {
			execID = DetachedExecs.randomID()
		}
		records[execID] = record
		return execID
	}

	/// 記下終局並淘汰超量的舊紀錄。只有第一次有效。
	/// - Parameters:
	///   - execID: 背景 exec 的 id。
	///   - outcome: 終局。
	///   - endedAt: 結束時間。
	/// - Returns: 記下終局後的紀錄；已記過或查無為 nil。
	internal mutating func finish(_ execID: String, outcome: MacGuestExecOutcome, endedAt: Date) -> Record? {
		guard
			var record: Record = records[execID],
			record.outcome == nil
		else { return nil }
		record.outcome = outcome
		record.endedAt = endedAt
		records[execID] = record
		finishedOrder.append(execID)
		while finishedOrder.count > DetachedExecs.finishedLimit {
			records[finishedOrder.removeFirst()] = nil
		}
		return record
	}

	// MARK: Private

	/// 終局 → 對外狀態。
	/// - Parameter outcome: 終局；nil＝還在跑。
	/// - Returns: 對外狀態。
	private static func state(of outcome: MacGuestExecOutcome?) -> ExecState {
		switch outcome {
		case nil:
			.running
		case .exited:
			.exited
		case .timedOut:
			.timedOut
		case .cancelled:
			.cancelled
		case .transportFailure:
			.failed
		}
	}

	/// 取最後 `limit` bytes 並解成文字；切點往後挪到 UTF-8 字元邊界。
	/// - Parameters:
	///   - data: 原始 bytes。
	///   - limit: 上限；nil＝全部。
	/// - Returns: 文字與是否被截短。
	private static func tail(of data: Data, limit: Int?) -> (text: String, cut: Bool) {
		guard
			let limit,
			data.count > max(0, limit)
		else { return (String(decoding: data, as: UTF8.self), false) }
		var start: Int = data.endIndex - max(0, limit)
		while start < data.endIndex, data[start] & 0b1100_0000 == 0b1000_0000 {
			start += 1
		}
		return (String(decoding: data[start...], as: UTF8.self), true)
	}

	/// 隨機 id：`exec-` 加 8 個 hex 字元；撞號由 ``insert(_:)`` 重抽。
	private static func randomID() -> String {
		let bytes: [UInt8] = (0 ..< 4).map { _ in UInt8.random(in: .min ... .max) }
		return "exec-" + bytes
			.map { String(format: "%02x", $0) }
			.joined()
	}

	/// id → 紀錄。
	private var records: [String: Record] = [:]

	/// 已結束的 id，依結束先後。
	private var finishedOrder: [String] = []
}
