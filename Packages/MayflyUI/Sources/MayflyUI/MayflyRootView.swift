//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// app 外殼的根畫面。
///
/// 現階段只做建置系統的落地證明——顯示 daemon socket 落點與存在性，證實 app bundle
/// 確實連得上引擎側的 package 圖。VM library 清單與 `.inspector` 細節面板為後續切片。
public struct MayflyRootView: View {

	private let endpoint: DaemonEndpoint

	/// - Parameter endpoint: 端點快照，預設於初始化當下解析一次（無自動輪詢）。
	public init(endpoint: DaemonEndpoint = .resolve()) {
		self.endpoint = endpoint
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(statusTitle, systemImage: statusSymbol)
				.font(.headline)
				.foregroundStyle(statusTint)
			Text(endpoint.socketPath)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.foregroundStyle(.secondary)
		}
		.padding(24)
		.frame(minWidth: 420, minHeight: 160, alignment: .topLeading)
	}

	/// 三個狀態映射刻意留在 internal：純映射反轉（把兩態寫顛倒）只有測試釘得住。
	var statusTitle: String {
		endpoint.isSocketPresent ? "daemon socket 存在" : "daemon socket 不存在"
	}

	/// 實心＝socket 在、空心＝不在，跟隨「填滿代表啟用中」的系統慣例。
	var statusSymbol: String {
		endpoint.isSocketPresent ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
	}

	/// 兩態另以顏色區分，避免只差填色時在一瞥距離下讀反。
	var statusTint: Color {
		endpoint.isSocketPresent ? .green : .secondary
	}
}
