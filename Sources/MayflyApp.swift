//
//  Mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import MayflyUI
import SwiftUI

/// app bundle 的進入點。
///
/// 本檔是 Xcode target 側**唯一**的原始碼——`@main` 屬性只能長在 app target 上，SwiftPM
/// library 產不出可簽章的 `.app`。畫面與邏輯全在 `Packages/MayflyUI`（掛得上 lint plugin、
/// 進得了 `swift test`），此處僅組裝 Scene，讓 Xcode-only 的表面積維持最小。
@main
struct MayflyApp: App {

	var body: some Scene {
		MayflyScene()
	}
}
