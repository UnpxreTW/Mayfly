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
/// 本型別只做組裝——載入、選取與錯誤全歸 ``SessionLibraryModel``。這裡是模組內**唯一**碰
/// 行程環境與檔案系統的地方（組裝時解析一次端點，見 ``init(resolveEndpoint:)``）；畫面本身
/// 不碰 socket，其餘型別一律吃注入進來的 ``DaemonEndpoint``。
public struct MayflyRootScreen: View {

	// MARK: Public

	/// 走真實 daemon 的預設組裝。
	///
	/// - Parameter resolveEndpoint: 端點解析。往返用的 socket 路徑由它給一次，失敗說明再向它要
	///   一次當下的落點事實（socket 檔可能中途出現或消失）。兩者共用同一份解析，畫面說的落點
	///   才會是真正連過的那個。
	@MainActor
	public init(resolveEndpoint: @escaping @Sendable () -> DaemonEndpoint = { .resolve() }) {
		self.init(
			model: SessionLibraryModel(
				querier: DaemonSessionQuerier(endpoint: resolveEndpoint()),
				resolveEndpoint: resolveEndpoint
			)
		)
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
		// 開場即取一次，之後每 2 秒自動重取；`.task` 在畫面離場時取消，輪詢隨之停下。
		.task {
			await model.pollForever()
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
