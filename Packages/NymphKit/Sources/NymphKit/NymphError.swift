//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// daemon 內部的失敗面——`SessionStore` / `GuestEngine` / `GuestControl` 擲此，於協議
/// 邊界 ``ToolError/init(_:)`` 映成對外 ``ToolError``（tool-error envelope）。與**遠端命令
/// 非零退出**互斥：後者是資料（回在 ``ExecuteResult/exit``）、不擲錯。契約通則見 #31：
/// no-such-id / 未 ready / SSH 傳輸失敗 / 逾時＝擲錯；命令非零 exit＝正常回傳。
public enum NymphError: Error, Sendable, Equatable {

	/// session table 無此 id。
	case noSuchID(String)

	/// 達併發上限、拒絕新 spawn（帶當前上限值）。
	case admissionDenied(limit: Int)

	/// golden 別名解析不到對應 bundle。
	case goldenNotFound(String)

	/// clone 失敗（跨卷 / 磁碟滿 / 佈局不完整等，帶底層描述）。
	case cloneFailed(String)

	/// 目標 session 未 ready（未 start / 開機中 / 已停）——無法連入執行。
	case notReady

	/// session 已 ready 但解不到 guest IP。
	case ipUnavailable

	/// SSH 傳輸層失敗（連不上 / 認證被拒 / sshd 未起；帶 ssh stderr）。
	case transportFailure(String)

	/// exec 逾 timeout 未結束、已被終止。
	case execTimedOut

	/// host 非 Apple Silicon（daemon 需 Virtualization.framework）。
	case notAppleSilicon

	/// 這個 daemon 沒有註冊對應 ``GuestKind`` 的引擎（請求合法、但此 host 開不了該種 guest）。
	case engineUnavailable(GuestKind)

	/// 其餘未歸類的內部錯誤（帶描述）。
	case internalFailure(String)
}
