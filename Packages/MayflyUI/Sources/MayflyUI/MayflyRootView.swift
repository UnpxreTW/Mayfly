//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// app 外殼的根畫面：左側 session 清單、右側細節欄。
///
/// 本型別只做組裝——載入、選取與錯誤全歸 ``SessionLibraryModel``，畫面本身不碰 socket、
/// 也不碰檔案系統。
public struct MayflyRootView: View {

	// MARK: Public

	/// 走真實 daemon 的預設組裝。
	@MainActor
	public init() {
		self.init(model: SessionLibraryModel())
	}

	public var body: some View {
		NavigationStack {
			SessionLibraryView(model: model)
				.navigationTitle("Sessions")
				.toolbar {
					// 兩顆按鈕都留在視窗主 toolbar：細節欄在窄視窗會收成覆蓋式面板，把切換鈕
					// 放進面板自己的 toolbar 會讓它跟著消失、之後開不回來。
					ToolbarItem {
						Button {
							Task { await model.refresh() }
						} label: {
							// 重載期間清單留在畫面上、不退回 spinner，進行中訊號因此掛在這顆
							// 按鈕上。**刻意不 disable**：往返沒有逾時，一旦 daemon 接了連線
							// 卻不回應，鎖住按鈕就等於鎖死唯一的復原入口。用疊加而非換掉 label，
							// 是為了讓 toolbar item 的寬度不隨狀態跳動、旁邊的鈕不位移。
							Label("重新載入", systemImage: "arrow.clockwise")
								.opacity(model.isReloading ? 0 : 1)
								.overlay {
									if model.isReloading {
										ProgressView()
											.controlSize(.small)
											.accessibilityHidden(true)
									}
								}
						}
						// 進行中狀態不能只有視覺：spinner 沒有可唸的值，狀態改由 value 帶；
						// 提示那句同時告訴使用者不必狂按（每按一次就多疊一條沒有逾時的往返）。
						.accessibilityLabel("重新載入")
						.accessibilityValue(model.isReloading ? "進行中" : "")
						.help(model.isReloading ? "仍在等待 daemon 回應" : "重新載入")
					}
					ToolbarItem {
						Button {
							isInspectorPresented.toggle()
						} label: {
							Label("細節欄", systemImage: "sidebar.right")
						}
					}
				}
		}
		// 細節欄掛在 `NavigationStack` 之外：掛在裡面會被算成導覽內容，toolbar 佔滿全寬、
		// 可捲內容被蓋住。寬度給區間而非定值，使用者拖過的寬度才留得住。
		.inspector(isPresented: $isInspectorPresented) {
			SessionInspectorView(phase: model.detailPhase)
				.inspectorColumnWidth(min: 260, ideal: 320, max: 420)
		}
		.frame(minWidth: 640, minHeight: 380)
		.task {
			await model.refresh()
		}
		.onChange(of: model.selectedSessionID) {
			Task { await model.loadDetail() }
		}
	}

	// MARK: Internal

	/// 注入式組裝（測試與預覽用）。
	@MainActor
	init(model: SessionLibraryModel) {
		_model = State(initialValue: model)
	}

	// MARK: Private

	@State private var model: SessionLibraryModel

	@State private var isInspectorPresented: Bool = true
}
