//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit
import SwiftUI

// MARK: - SessionInspectorView

/// 細節欄：對映 ``SessionLibraryModel/DetailPhase`` 的四態。欄位順序與 `status` 動詞的
/// 回傳同序，看畫面與看 CLI 輸出是同一份心智模型。
struct SessionInspectorView: View {

	let phase: SessionLibraryModel.DetailPhase

	var body: some View {
		switch phase {
		case .empty:
			ContentUnavailableView(
				"未選取 session",
				systemImage: "sidebar.right",
				description: Text("在清單選一個 session 看它的細節。")
			)

		case let .loading(summary):
			SessionDetailForm(summary: summary, stopReason: nil, note: "更新中…")

		case let .loaded(result):
			SessionDetailForm(summary: result.summary, stopReason: result.stopReason, note: nil)

		case let .failed(summary, failure):
			SessionDetailForm(
				summary: summary,
				stopReason: nil,
				note: "\(failure.headline)：\(failure.guidance)"
			)
		}
	}
}

// MARK: - SessionDetailForm

/// 細節欄位表。`note` 承接「這份資料不是最新／取不到最新」的說明，讓過期資料留在畫面上
/// 但不假裝它是當下狀態。
private struct SessionDetailForm: View {

	let summary: SessionSummary

	let stopReason: String?

	let note: String?

	var body: some View {
		Form {
			LabeledContent("ID", value: summary.id)
			LabeledContent("狀態", value: summary.state.displayName)
			LabeledContent("IP", value: SessionFormatting.address(summary.ip))
			LabeledContent("golden", value: summary.golden)
			LabeledContent("vCPU", value: "\(summary.cpus)")
			LabeledContent("記憶體", value: SessionFormatting.memory(gib: summary.memoryGiB))
			LabeledContent("存活時間", value: SessionFormatting.uptime(seconds: summary.uptimeSeconds))
			if let stopReason {
				LabeledContent("停止原因", value: stopReason)
			}
			if let note {
				Text(note)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}
