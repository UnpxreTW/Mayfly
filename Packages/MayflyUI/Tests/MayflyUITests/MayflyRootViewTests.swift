//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Testing

@testable import MayflyUI

// MARK: - MayflyRootViewTests

private final class MayflyRootViewTests {

	/// 實心 symbol 只給「socket 存在」態——兩態寫顛倒是純映射錯誤、編譯與 lint 都攔不到。
	@Test
	private func `status symbol fills only when the socket is present`() {
		#expect(view(socketPresent: true).statusSymbol == "bolt.horizontal.circle.fill")
		#expect(view(socketPresent: false).statusSymbol == "bolt.horizontal.circle")
	}

	/// 標題與顏色兩態都要分得開，否則只剩填色差異、一瞥距離下讀不出來。
	@Test
	private func `status title and tint differ between the two states`() {
		#expect(view(socketPresent: true).statusTitle != view(socketPresent: false).statusTitle)
		#expect(view(socketPresent: true).statusTint != view(socketPresent: false).statusTint)
	}

	private func view(socketPresent: Bool) -> MayflyRootView {
		let endpoint: DaemonEndpoint = .init(
			socketPath: "/tmp/mayfly-root-view-test/nymph.sock",
			isSocketPresent: socketPresent
		)
		return MayflyRootView(endpoint: endpoint)
	}
}
