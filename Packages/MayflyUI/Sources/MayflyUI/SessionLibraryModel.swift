//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// session library 的畫面狀態機——載入、選取、錯誤收斂都在這裡，View 只讀狀態、不做決定。
///
/// 資料經注入的 ``SessionQuerying`` 取得，端點快照由注入的 closure 在**往返失敗時**才解析
/// （socket 可能中途出現或消失，失敗當下的事實才有說明價值），因此整顆 model 在沒有
/// daemon 的機器上也測得動。
///
/// **陳舊回應防護**：``refresh()`` 與 ``loadDetail()`` 進場各取一個世代號，`await` 回來時
/// 世代已被更新的呼叫推進就丟棄結果——重載互踩與快速換選取都靠這個擋。
@MainActor
@Observable
public final class SessionLibraryModel {

	// MARK: Public

	/// 清單的三態。
	public enum LibraryPhase: Equatable, Sendable {

		/// 載入中（含重載）。
		case loading

		/// 已載入；空陣列＝沒有 session，是正常態、不是錯誤。
		case loaded([SessionSummary])

		/// 取不到清單。
		case unavailable(DaemonFailure)
	}

	/// 細節欄的四態。
	public enum DetailPhase: Equatable, Sendable {

		/// 未選取任何 session。
		case empty

		/// 已有清單摘要可先顯示、完整狀態還在路上。
		case loading(SessionSummary)

		/// 已取得完整狀態（含 stop reason）。
		case loaded(StatusResult)

		/// 狀態取不到——例如 session 在列出與點選之間被回收。
		case failed(SessionSummary, DaemonFailure)
	}

	/// 清單狀態。
	public private(set) var libraryPhase: LibraryPhase = .loading

	/// 細節欄狀態。
	public private(set) var detailPhase: DetailPhase = .empty

	/// 是否有重載在途。清單已在畫面上時不會退回 `loading`，進行中訊號改由這個旗標帶——
	/// 沒有它，按下重新載入到結果回來之間畫面完全靜止、使用者無從得知點擊是否生效。
	public private(set) var isReloading: Bool = false

	/// 目前選取的 session id。
	///
	/// - Important: 由清單綁定直接寫入，**寫入端負責接著呼叫 ``loadDetail()``**（畫面以
	///   `onChange` 接）；``refresh()`` 內部的選取變動則自行處理，不需外部補呼叫。
	public var selectedSessionID: String?

	/// - Parameters:
	///   - querier: daemon 往返；預設走真實 socket。
	///   - resolveEndpoint: 端點快照解析，僅在往返失敗、需要說明探過哪個落點時呼叫。
	public init(
		querier: any SessionQuerying = DaemonSessionQuerier(),
		resolveEndpoint: @escaping @Sendable () -> DaemonEndpoint = { .resolve() }
	) {
		self.querier = querier
		self.resolveEndpoint = resolveEndpoint
	}

	/// 重新取清單。選取的 session 還在就順帶重取它的狀態（否則按下重新載入只會更新半個
	/// 畫面）；已不在新清單裡則清掉選取與細節欄。
	public func refresh() async {
		libraryGeneration += 1
		let generation: Int = libraryGeneration
		// 已有清單就留在畫面上：打回 spinner 會丟掉捲動位置，也會讓細節欄一瞬間查不到摘要。
		if !hasLoadedSessions {
			libraryPhase = .loading
		}
		isReloading = true
		// 只有最新那次重載能收掉旗標；被蓋過的那次回來時不動它。
		defer {
			if generation == libraryGeneration {
				isReloading = false
			}
		}
		do {
			// 恆含 stopped：library 視角要看得到剛停下的 session，也才有 stop reason 可看。
			let result: ListResult = try await querier.listSessions(includeStopped: true)
			guard generation == libraryGeneration else {
				return
			}
			libraryPhase = .loaded(result.sessions)
			// 先執行再判斷：清選取有副作用，不放進短路條件裡（條件順序一調動就會被跳過）。
			let vanished: Bool = pruneSelectionIfVanished(from: result.sessions)
			guard !vanished, selectedSessionID != nil else {
				return
			}
			await loadDetail()
		} catch {
			guard generation == libraryGeneration else {
				return
			}
			libraryPhase = .unavailable(DaemonFailure(mapping: error, endpoint: resolveEndpoint()))
		}
	}

	/// 取目前選取 session 的完整狀態；沒有選取（或選取已不在清單中）就清空細節欄。
	public func loadDetail() async {
		detailGeneration += 1
		let generation: Int = detailGeneration
		guard let id: String = selectedSessionID, let summary: SessionSummary = summary(for: id) else {
			detailPhase = .empty
			return
		}
		detailPhase = .loading(summary)
		do {
			let result: StatusResult = try await querier.sessionStatus(id: id)
			guard generation == detailGeneration else {
				return
			}
			detailPhase = .loaded(result)
		} catch {
			guard generation == detailGeneration else {
				return
			}
			// 端點只在說明失敗時才需要，解析留到這裡、不擺在每次往返的順利路徑上。
			detailPhase = .failed(summary, DaemonFailure(mapping: error, endpoint: resolveEndpoint()))
		}
	}

	/// 目前已載入的清單；非 `loaded` 態一律空陣列。
	var sessions: [SessionSummary] {
		guard case let .loaded(sessions) = libraryPhase else {
			return []
		}
		return sessions
	}

	// MARK: Private

	private let querier: any SessionQuerying

	private let resolveEndpoint: @Sendable () -> DaemonEndpoint

	private var libraryGeneration: Int = 0

	private var detailGeneration: Int = 0

	/// 已有清單可留在畫面上（重載期間不清空）。
	private var hasLoadedSessions: Bool {
		if case .loaded = libraryPhase {
			return true
		}
		return false
	}

	private func summary(for id: String) -> SessionSummary? {
		sessions.first { $0.id == id }
	}

	/// 選取的 session 已不在新清單裡就清掉它，回傳是否清過。
	///
	/// 一併推進細節欄世代：在途的狀態查詢回來時才不會把已消失 session 的資料寫回畫面。
	private func pruneSelectionIfVanished(from sessions: [SessionSummary]) -> Bool {
		guard let id: String = selectedSessionID, !sessions.contains(where: { $0.id == id }) else {
			return false
		}
		detailGeneration += 1
		selectedSessionID = nil
		detailPhase = .empty
		return true
	}
}
