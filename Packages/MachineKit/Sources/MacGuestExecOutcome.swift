//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一次 guest 內命令執行的終局。
public enum MacGuestExecOutcome: Sendable, Equatable {

	/// 命令自行結束（結束碼是資料，非零照樣是這一型）。
	case exited(Int32)

	/// 超過等待上限、已走終止流程結束。
	case timedOut

	/// 被呼叫端取消、已走終止流程結束。
	case cancelled

	/// SSH 傳輸層失敗（ssh 以 255 收斂；帶 ssh stderr）。
	case transportFailure(String)
}
