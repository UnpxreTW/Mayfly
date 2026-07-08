//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// ``GuestExec`` 的失敗情形——**皆為傳輸 / 前置錯誤**（tool-error 面），與遠端命令
/// 的非零退出（資料、回在 ``GuestExecResult/exitCode``）互斥。契約見 #31：no-such /
/// 未 ready / SSH 傳輸失敗 / 逾時＝擲錯；命令非零 exit＝正常回傳。
///
/// （no-such-id 屬 daemon 的 session table 層〔實作順序②〕、本引擎切片不涉；引擎層
/// 對應的是 ``notReady``。）
public enum GuestExecError: Error, Equatable, Sendable {

	/// 目標 session 尚未 ready（未 start / 開機中 / 已停）——無法連入執行。
	case notReady

	/// session 已 ready 但解不到 guest IP（lease 尚未寫入 / 已釋放）。
	case ipUnavailable

	/// SSH 傳輸層失敗：連不上 / 認證被拒 / 遠端 sshd 未起（ssh 以 255 收斂）。帶 ssh
	/// 的 stderr 供 triage。
	case transportFailure(String)

	/// 命令逾 `timeout` 未結束、已被終止。
	case timedOut(Duration)

	/// ssh 客戶端本身起不來（二進位不存在 / spawn 失敗）。帶底層錯誤描述。
	case launchFailed(String)
}
