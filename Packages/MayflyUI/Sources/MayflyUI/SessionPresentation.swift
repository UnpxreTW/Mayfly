//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit
import SwiftUI

// MARK: - SessionState display mapping

/// 狀態 → 畫面元素的映射。刻意留在 internal 而非藏進 View：純映射（把兩態寫顛倒、四態
/// 少一態）編譯器與 lint 都攔不到，只有測試釘得住。
extension SessionState {

	/// 列表與細節欄共用的狀態名。
	var displayName: String {
		switch self {
		case .idle:
			return "閒置"

		case .booting:
			return "開機中"

		case .ready:
			return "就緒"

		case .stopped:
			return "已停止"
		}
	}

	/// 只有 `ready` 用實心，跟隨「填滿代表啟用中」的系統慣例。
	var symbolName: String {
		switch self {
		case .idle:
			return "circle"

		case .booting:
			return "circle.dotted"

		case .ready:
			return "circle.fill"

		case .stopped:
			return "stop.circle"
		}
	}

	/// 兩個「不在跑」的狀態另以顏色與就緒／開機中分開，避免只差符號時一瞥讀反。
	var tint: Color {
		switch self {
		case .idle:
			return .secondary

		case .booting:
			return .orange

		case .ready:
			return .green

		case .stopped:
			return .secondary
		}
	}
}

// MARK: - SessionFormatting

/// 數值欄位的顯示格式（清單列與細節欄共用同一份，兩處才不會各自漂移）。
enum SessionFormatting {

	/// 存活秒數 → `45 s` / `3 m 5 s` / `2 h 1 m`；負值視為 0。
	static func uptime(seconds: Int) -> String {
		let total: Int = max(0, seconds)
		if total < 60 {
			return "\(total) s"
		}
		if total < 3600 {
			return "\(total / 60) m \(total % 60) s"
		}
		return "\(total / 3600) h \(total % 3600 / 60) m"
	}

	/// 記憶體 GiB → `4 GiB`。
	static func memory(gib: Int) -> String {
		"\(gib) GiB"
	}

	/// IP；尚未解出時給破折號、不留空白格。
	static func address(_ ipAddress: String?) -> String {
		ipAddress ?? "—"
	}
}
