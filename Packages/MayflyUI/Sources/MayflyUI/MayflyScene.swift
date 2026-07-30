//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// app 外殼的根 Scene——`@main` 進入點只組裝它，畫面結構全留在本 package 內（可 lint、
/// 可單測），Xcode target 側維持最薄。
public struct MayflyScene: Scene {

	public init() {}

	public var body: some Scene {
		WindowGroup {
			MayflyRootScreen()
		}
	}
}
