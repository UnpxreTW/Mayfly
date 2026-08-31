//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 要開哪一種 guest——引擎選擇是 spawn 的真語義參數，故住線協議，不由別名字面推斷：
/// ``GoldenResolver``（golden 路徑別名）與 Linux 側 image 別名的裸別名空間重疊，靠字面
/// 自動分流會在同名別名上靜默選錯引擎。未知字面值或缺欄於解碼即失敗（大聲失敗、不猜）。
public enum GuestKind: String, Codable, Sendable, Equatable, CaseIterable {

	/// macOS guest。
	case mac

	/// Linux guest。
	case linux
}
