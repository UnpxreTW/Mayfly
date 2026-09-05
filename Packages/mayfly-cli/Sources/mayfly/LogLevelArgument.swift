//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Logging

/// `--log-level` 的可選值——`Logging.Logger.Level` 的鏡像。
///
/// 不直接讓 `Logger.Level` 認 `ExpressibleByArgument`：型別與協定分屬兩個外部模組，補這個
/// 一致性得標 `@retroactive`、而且會讓全 repo 都吃到那份宣告。自家鏡像多十行，換來 `--help`
/// 列值的順序由這裡定、也不動別人的型別。
internal enum LogLevelArgument: String, CaseIterable, ExpressibleByArgument {

	/// 逐步追蹤。
	case trace

	/// 除錯細節。
	case debug

	/// 預設門檻：值得留下的事件。
	case info

	/// 需要留意、但不影響進行。
	case notice

	/// 有異狀。
	case warning

	/// 操作失敗。
	case error

	/// 只留最嚴重的。
	case critical

	/// 對應的紀錄層級。
	internal var level: Logger.Level {
		switch self {
		case .trace: .trace
		case .debug: .debug
		case .info: .info
		case .notice: .notice
		case .warning: .warning
		case .error: .error
		case .critical: .critical
		}
	}
}
