//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging
import Synchronization

/// 這支 binary 的兩條輸出面：紀錄走 `Logger`（stderr、逐行送出），要被取用的資料走 stdout。
///
/// 紀錄的後端只在這裡裝一次（見 ``bootstrap()``），函式庫那一層只拿 `Logger`、不知道也不決定
/// 紀錄最後寫去哪裡。以檔案承接輸出時 stdout 是整塊緩衝的，常駐 daemon 又是被強制結束的，那
/// 一塊從來沒有機會落地 ⇒ 紀錄一律走 `StreamLogHandler.standardError`：逐行送出，寫進檔案的
/// 那一行不必等行程收工。
///
/// 門檻另存一份（見 ``setLogLevel(_:)``）：後端要在解析 argv 之前裝好，而門檻要等解析完才
/// 知道（見 ``LoggingOptions``），兩件事的時序拆不到同一刻。
internal enum CommandOutput {

	/// 這個行程的紀錄出口；所有子命令共用同一個標籤。
	internal static let logger: Logger = .init(label: "mayfly")

	/// 裝上紀錄後端。
	///
	/// 後端只能裝一次、且要在第一行紀錄送出之前，因此固定由這支 binary 的進入點起手呼叫。
	internal static func bootstrap() {
		LoggingSystem.bootstrap { label in
			var stream: StreamLogHandler = .standardError(label: label)
			// 過濾一律由 ``LevelGate`` 做；下游自己那份門檻開到底，免得兩層各擋各的。
			stream.logLevel = .trace
			return LevelGate(downstream: stream)
		}
	}

	/// 設定這個行程的紀錄門檻。低於門檻的紀錄不送出。
	///
	/// - Parameter level: 新門檻。
	internal static func setLogLevel(_ level: Logger.Level) {
		threshold.withLock { $0 = level }
	}

	/// 目前的紀錄門檻。
	internal static var logLevel: Logger.Level {
		threshold.withLock { $0 }
	}

	/// 門檻本體。行程級單一值，daemon 是多執行緒的 ⇒ 上鎖。
	private static let threshold: Mutex<Logger.Level> = .init(.info)

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
