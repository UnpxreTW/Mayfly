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
///
/// 自動更新的說明條掛在 `body` 上、**不掛在任何一個相位分支裡**：空表與錯誤頁同樣需要那行字
/// ——最容易被當成事實的畫面正是「沒有 session」，它必須說得出自己已經停止更新。
struct SessionLibraryView: View {

	@Bindable var model: SessionLibraryModel

	var body: some View {
		content
			// 說明條掛在最外層、不只掛在有清單那一態：空表（「一開 app 什麼都沒有」的常態）
			// 若少了這行，畫面只會寫「沒有 session」而不提那份判斷已經停止更新。
			.safeAreaInset(edge: .bottom) {
				if let issue: SessionLibraryModel.BackgroundIssue = model.backgroundIssue {
					BackgroundIssueNote(issue: issue)
				}
			}
	}

	// MARK: Private

	@ViewBuilder
	private var content: some View {
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

// MARK: - BackgroundIssueNote

/// 自動更新的說明條。
private struct BackgroundIssueNote: View {

	let issue: SessionLibraryModel.BackgroundIssue

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "exclamationmark.triangle")
			Text(issue.note)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.bar)
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
