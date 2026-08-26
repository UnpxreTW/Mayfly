//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// daemon 對外暴露的 session 狀態——鏡射引擎 `GuestSession.State`、但去掉 associated
/// IP（IP 在協議層是獨立欄位）。刻意做成 arch-neutral 的獨立列舉（不引用 arm64-gated
/// 的 `GuestSession.State`）：`SessionStore` 與協議層因此可跨 arch 建 / 測（fake），真機
/// 對映集中在 arm64 的 ``RealGuestControl``。值對映契約 #31 的 state 字串。
public enum SessionState: String, Sendable, Equatable, Codable {

	/// 尚未 start。
	case idle

	/// 開機中、readiness 未收斂。
	case booting

	/// 已收斂（IP 由協議層另欄帶；沒接對外網路的 guest 是 ready 但 IP 為 nil，readiness
	/// 逾時則不升 ready、留在 booting，見 NY-1）。
	case ready

	/// 已停止（自行關機 / 錯誤 / 硬停）。
	case stopped
}
