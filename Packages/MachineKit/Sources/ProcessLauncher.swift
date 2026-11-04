//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 啟動一個外部行程、**不等它結束**的執行器抽象：stdout / stderr 隨行程吐出逐段寫進呼叫端
/// 給的 ``OutputTailBuffer``，呼叫端拿回 ``LaunchedProcess`` 自行等待或終止。
///
/// 與 ``ProcessRunner`` 的差異：``ProcessRunner`` 一次跑完、結束才回完整輸出；本協定給的是
/// 執行中就能看輸出、能從外部終止的那一種。抽成協定的理由同 ``ProcessRunner``——讓
/// ``MacGuestExec`` 的 argv 構造與終止流程可以注入假執行器單測。真實作見 ``SystemProcessRunner``。
public protocol ProcessLauncher: Sendable {

	/// 啟動 `executable` 帶 `arguments`。
	///
	/// - Parameters:
	///   - executable: 執行檔路徑。
	///   - arguments: 參數。
	///   - standardInput: 寫入行程 stdin 後關閉；nil 則立即關端（送 EOF）。
	///   - standardOutput: stdout 的落點。
	///   - standardError: stderr 的落點。
	/// - Returns: 已啟動的行程。
	/// - Throws: 行程起不來（執行檔不存在 / 沙箱拒絕）。
	func launch(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) throws -> any LaunchedProcess
}
