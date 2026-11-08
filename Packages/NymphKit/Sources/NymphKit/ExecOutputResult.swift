//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - ExecOutputResult

/// 背景 exec 的輸出與狀態。
///
/// 每條串流各保留最後 1 MiB；超過時丟頭留尾、對應的截斷旗標變 true。
public struct ExecOutputResult: Codable, Sendable, Equatable {

	/// 目前狀態。
	public let state: ExecState

	/// 標準輸出（保留的尾段）。
	public let standardOutput: String

	/// 標準錯誤（保留的尾段）。
	public let standardError: String

	/// 標準輸出是否不是全文（緩衝丟過開頭，或被 `tailBytes` 截短）。
	public let standardOutputTruncated: Bool

	/// 標準錯誤是否不是全文。
	public let standardErrorTruncated: Bool

	/// 最後一次收到任一串流輸出的時間；從未輸出為 nil。
	public let lastOutputAt: Date?

	/// 結束碼；只有 ``ExecState/exited`` 才有。
	public let exit: Int32?

	/// 結束時間；還在跑為 nil。
	public let endedAt: Date?

	/// 建立背景 exec 的輸出與狀態。
	/// - Parameters:
	///   - state: 目前狀態。
	///   - standardOutput: 標準輸出（保留的尾段）。
	///   - standardError: 標準錯誤（保留的尾段）。
	///   - standardOutputTruncated: 標準輸出是否不是全文。
	///   - standardErrorTruncated: 標準錯誤是否不是全文。
	///   - lastOutputAt: 最後一次收到任一串流輸出的時間。
	///   - exit: 結束碼；只有 ``ExecState/exited`` 才有。
	///   - endedAt: 結束時間；還在跑為 nil。
	public init(
		state: ExecState,
		standardOutput: String,
		standardError: String,
		standardOutputTruncated: Bool,
		standardErrorTruncated: Bool,
		lastOutputAt: Date?,
		exit: Int32?,
		endedAt: Date?
	) {
		self.state = state
		self.standardOutput = standardOutput
		self.standardError = standardError
		self.standardOutputTruncated = standardOutputTruncated
		self.standardErrorTruncated = standardErrorTruncated
		self.lastOutputAt = lastOutputAt
		self.exit = exit
		self.endedAt = endedAt
	}
}
