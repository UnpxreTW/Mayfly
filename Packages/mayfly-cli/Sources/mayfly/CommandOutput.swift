//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging

/// 這支 binary 的兩條輸出面：紀錄走 `Logger`（stderr、逐行送出），要被取用的資料走 stdout。
///
/// 紀錄的後端只在這裡裝一次（見 ``bootstrap()``），函式庫那一層只拿 `Logger`、不知道也不決定
/// 紀錄最後寫去哪裡。以檔案承接輸出時 stdout 是整塊緩衝的，常駐 daemon 又是被強制結束的，那
/// 一塊從來沒有機會落地 ⇒ 紀錄一律走 `StreamLogHandler.standardError`：逐行送出，寫進檔案的
/// 那一行不必等行程收工。
internal enum CommandOutput {

	/// 這個行程的紀錄出口；所有子命令共用同一個標籤。
	internal static let logger: Logger = .init(label: "mayfly")

	/// 裝上紀錄後端。
	///
	/// 後端只能裝一次、且要在第一行紀錄送出之前，因此固定由這支 binary 的進入點起手呼叫。
	internal static func bootstrap() {
		LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
	}

	/// 把一行要被取用的資料寫進 stdout。
	///
	/// clone 路徑、session 表格、`READY ip=` 這些是呼叫端要讀走的內容、不是紀錄：混進帶時間戳
	/// 與標籤的紀錄行裡就不再是可直接取用的形狀。直接寫 handle 而不經 `print`——stdout 接 pipe
	/// 時 `print` 會整塊緩衝，讀的那一端等不到行。
	///
	/// - Parameter line: 要寫出去的內容；換行由這裡補上。
	internal static func write(_ line: String) {
		FileHandle.standardOutput.write(Data((line + "\n").utf8))
	}
}
