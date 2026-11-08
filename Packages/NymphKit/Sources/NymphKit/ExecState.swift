//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - ExecState

/// 背景 exec 的狀態。
public enum ExecState: String, Codable, Sendable, Equatable {

	/// 還在跑。
	case running

	/// 命令自行結束（結束碼在 ``ExecOutputResult/exit``，非零照樣是這一型）。
	case exited

	/// 超過 `timeoutSeconds`、已走終止流程結束。
	case timedOut = "timed_out"

	/// SSH 傳輸層失敗（ssh 的訊息在 ``ExecOutputResult/standardError``）。
	case failed

	/// 被取消（呼叫端取消，或所屬 session 被 destroy／drain）、已走終止流程結束。
	case cancelled
}
