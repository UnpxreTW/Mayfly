//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// Linux 容器要不要接網路——由 daemon 啟動參數決定，整支 daemon 一個值。
public enum LinuxNetworkMode: String, Sendable, CaseIterable {

	/// 接一張 vmnet 共享網路：容器配得到 IPv4 位址、能對外連線。
	case vmnet

	/// 不接網路：容器內只有 lo，``LinuxGuestControl`` 回報的位址恆為 nil。
	///
	/// - Note: case 名不叫 `none`——它在 optional 上下文會與 `Optional.none` 撞名，
	///   讀的人得先分辨這是哪一個 `none`。對外的字面值仍是 `none`（rawValue）。
	case disabled = "none"
}
