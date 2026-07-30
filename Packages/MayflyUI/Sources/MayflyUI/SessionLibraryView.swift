//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit
import SwiftUI

// MARK: - SessionLibraryView

/// session 清單欄：四種呈現（載入中／空表／清單／取不到），選取直接寫回 model。
struct SessionLibraryView: View {

	@Bindable var model: SessionLibraryModel

	var body: some View {
		switch model.libraryPhase {
		case .loading:
			ProgressView()
				.frame(maxWidth: .infinity, maxHeight: .infinity)

		case let .loaded(sessions) where sessions.isEmpty:
			ContentUnavailableView(
				"沒有 session",
				systemImage: "tray",
				description: Text("daemon 目前沒有任何 session。")
			)

		case let .loaded(sessions):
			List(selection: $model.selectedSessionID) {
				ForEach(sessions, id: \.id) { session in
					SessionRow(session: session)
				}
			}

		case let .unavailable(failure):
			ContentUnavailableView {
				Label(failure.headline, systemImage: "bolt.horizontal.circle")
			} description: {
				Text(failure.guidance)
			} actions: {
				// 不隨 `isReloading` 停用：這是取不到清單時唯一的復原入口，而往返沒有逾時。
				Button("重試") {
					Task { await model.refresh() }
				}
			}
		}
	}
}

// MARK: - SessionRow

/// 清單單列：狀態燈號 ＋ id ＋（golden・存活時間）＋ 狀態名。
private struct SessionRow: View {

	let session: SessionSummary

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: session.state.symbolName)
				.foregroundStyle(session.state.tint)
			VStack(alignment: .leading, spacing: 2) {
				Text(session.id)
					.font(.system(.body, design: .monospaced))
				Text("\(session.golden) · \(SessionFormatting.uptime(seconds: session.uptimeSeconds))")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Text(session.state.displayName)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(.vertical, 2)
	}
}
