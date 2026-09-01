//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一次 guest 內命令執行的結果封套：stdout / stderr 文字與結束碼。
///
/// **結束碼是資料**——命令跑完回非零是正常結果（契約 #31）、非工具錯誤；傳輸層
/// 失敗（連不上 / 認證被拒 / 逾時）才由 ``MacGuestExec`` 擲 ``MacGuestExecError``。stdout /
/// stderr 以 UTF-8 解碼（無法解的 byte 以替代字元帶過、不丟失長度資訊）。
public struct GuestExecResult: Sendable, Equatable {

	/// 標準輸出（UTF-8 解碼）。
	public let standardOutput: String

	/// 標準錯誤（UTF-8 解碼）。
	public let standardError: String

	/// 命令結束碼（遠端命令的真實退出碼）。
	public let exitCode: Int32

	public init(standardOutput: String, standardError: String, exitCode: Int32) {
		self.standardOutput = standardOutput
		self.standardError = standardError
		self.exitCode = exitCode
	}
}
