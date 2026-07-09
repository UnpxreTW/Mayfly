//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 跑一個外部行程、回**完整結果**（stdout / stderr / 結束碼）的執行器抽象。
///
/// 與 ``CommandRunner`` 的關鍵差異：``CommandRunner`` 把非零 exit 當**失敗**擲錯、
/// 只回 stdout；本協定把**結束碼當資料**（非零是正常 envelope）、stdout 與 stderr
/// 分開回傳——``GuestExec`` 要的正是這語義（遠端命令非零退出是結果、非傳輸錯誤）。
/// 抽成協定是為了讓 ``GuestExec`` 的 **argv 構造與結果 / 錯誤映射可單測**：測試注入
/// 假執行器、驗「下了什麼 ssh 指令、把結果映成什麼」，完全不必真連 VM。真實作見
/// ``SystemProcessRunner``。
public protocol ProcessRunner: Sendable {

	/// 跑 `executable` 帶 `arguments`；`standardInput` 非 nil 則寫入行程 stdin 後關閉、
	/// nil 則立即關端（送 EOF）。`timeout` 非 nil 且逾時 → 終止行程並擲
	/// ``ProcessRunnerError/timedOut(_:)``。回 ``ProcessRunResult``（含非零結束碼、不擲
	/// 錯）；唯行程**起不來**（executable 不存在 / 沙箱拒絕）或逾時才擲錯。
	func run(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		timeout: Duration?
	) async throws -> ProcessRunResult
}

/// 一次行程執行的完整結果：stdout / stderr 的原始 bytes 與行程結束碼。
///
/// 結束碼是資料——非零由呼叫端依語境詮釋（``GuestExec`` 視 255 為 SSH 傳輸失敗、
/// 其餘為遠端命令的真實退出碼）。
public struct ProcessRunResult: Sendable {

	/// 標準輸出的原始 bytes。
	public let standardOutput: Data

	/// 標準錯誤的原始 bytes。
	public let standardError: Data

	/// 行程結束碼（`Process.terminationStatus`）。
	public let exitCode: Int32

	public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
		self.standardOutput = standardOutput
		self.standardError = standardError
		self.exitCode = exitCode
	}
}

/// ``ProcessRunner`` 的執行期失敗——**與遠端命令非零退出無關**（那是資料、回在
/// ``ProcessRunResult`` 裡）。
public enum ProcessRunnerError: Error, Equatable, Sendable {

	/// 逾時：行程逾 `timeout` 未結束、已被終止。帶逾時長度供上層映射訊息。
	case timedOut(Duration)
}
