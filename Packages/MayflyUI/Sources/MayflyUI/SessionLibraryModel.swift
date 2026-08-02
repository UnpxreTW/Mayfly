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

	/// 自動更新的兩種異常。
	public enum BackgroundIssue: Equatable, Sendable {

		/// 上一次往返還沒回來，這一拍被略過（往返沒有逾時，不能一直往上疊）。
		case stalled

		/// 自動更新失敗，但畫面上的清單保留——一次瞬時失敗不該清掉整份庫存。
		case failed(DaemonFailure)
	}

	/// **使用者要求的**重載是否在途（自動更新不動它，見 ``pollForever()``）。清單已在畫面上時
	/// 不會退回 `loading`，進行中訊號改由這個旗標帶——沒有它，按下重新載入到結果回來之間畫面
	/// 完全靜止、使用者無從得知點擊是否生效。
	public private(set) var isReloading: Bool = false

	/// 自動更新的異常訊號；`nil`＝最近一次自動更新是好的。
	///
	/// 自動更新是背景行為，出事時**不搶畫面**：清單留著、只在旁邊說明現況。沒有這個訊號，
	/// 卡住或失敗的自動更新會靜靜停在原地，而畫面看起來一切正常——那比不更新更糟。
	public private(set) var backgroundIssue: BackgroundIssue?

	/// 目前選取的 session id。
	///
	/// - Important: 由清單綁定直接寫入，**寫入端負責接著呼叫 ``loadDetail()``**（畫面以
	///   `onChange` 接）；重載內部的選取變動（選取的 session 從清單消失）由重載自行處理，
	///   ``refresh()`` 與 ``pollForever()`` 兩個入口皆然，不需外部補呼叫。
	public var selectedSessionID: String?

	/// - Parameters:
	///   - querier: daemon 往返。
	///   - resolveEndpoint: 端點快照解析，僅在往返失敗、需要說明探過哪個落點時呼叫。
	///   - pollInterval: 背景輪詢的間隔，見 ``pollForever()``。
	public init(
		querier: any SessionQuerying,
		resolveEndpoint: @escaping @Sendable () -> DaemonEndpoint = { .resolve() },
		pollInterval: Duration = .seconds(2)
	) {
		self.querier = querier
		self.resolveEndpoint = resolveEndpoint
		self.pollInterval = pollInterval
	}

	/// 使用者要求的重新載入：帶進行中訊號，且**不因既有往返在途而略過**。
	public func refresh() async {
		await reload(announcesProgress: true)
	}

	/// 每 `pollInterval` 自動重取一次，直到所屬 `Task` 被取消（畫面離場即停）。
	///
	/// 只能輪詢：協議是一問一答、沒有訂閱面，session 狀態變了不會有人通知我們。間隔預設
	/// 2 秒——VM 的狀態轉移以十秒計，而每次 tick 只是一次連線加一行 JSON。
	///
	/// 輪詢刻意**安靜**：不動進行中旗標、不打回 spinner、細節欄也不打「更新中…」。每兩秒閃
	/// 一次的訊號分不出是自動更新還是使用者剛按的鈕，反而讓真正的手動重載失去回饋。
	/// 安靜不等於沉默——出事時走 ``backgroundIssue``，見該處。
	public func pollForever() async {
		while !Task.isCancelled {
			pollTicks += 1
			await reload(announcesProgress: false)
			do {
				try await Task.sleep(for: pollInterval)
			} catch {
				// 取消是這裡唯一的擲出來源；迴圈就此收束，不再發下一次往返。
				return
			}
		}
	}

	/// 取目前選取 session 的完整狀態；沒有選取（或選取已不在清單中）就清空細節欄。
	public func loadDetail() async {
		await loadDetail(announcesProgress: true)
	}

	/// 目前已載入的清單；非 `loaded` 態一律空陣列。
	var sessions: [SessionSummary] {
		guard case let .loaded(sessions) = libraryPhase else {
			return []
		}
		return sessions
	}

	/// ``pollForever()`` 跑過的拍數（含被略過的那些）。
	///
	/// 給測試判定「迴圈確實還在動」用——靠睡一段時間再數呼叫次數的話，機器一忙就會變成
	/// 「沒 tick 也照樣通過」的假綠。
	private(set) var pollTicks: Int = 0

	// MARK: Private

	private let querier: any SessionQuerying

	private let resolveEndpoint: @Sendable () -> DaemonEndpoint

	private let pollInterval: Duration

	private var libraryGeneration: Int = 0

	private var detailGeneration: Int = 0

	/// 經 ``reload(announcesProgress:)`` 發出、尚未回來的往返數。輪詢靠它避免堆疊。
	///
	/// - Important: **不含**選取變動觸發的 ``loadDetail()``。那條是使用者當下的操作、不能略過，
	///   而它同樣擋不住堆疊——真正的解是傳輸層的逾時與取消（尚未有，見 ``DaemonSessionQuerier``）。
	///   在那之前這個計數保證的是：使用者已經堆起來的往返之上，自動更新**至多再加一條**
	///   （某一拍先通過節流、隨後才卡住），不會每拍再補。
	private var roundTripsInFlight: Int = 0

	/// 已有清單可留在畫面上（重載期間不清空）。
	private var hasLoadedSessions: Bool {
		if case .loaded = libraryPhase {
			return true
		}
		return false
	}

	/// 重新取清單。選取的 session 還在就順帶重取它的狀態（否則按下重新載入只會更新半個
	/// 畫面）；已不在新清單裡則清掉選取與細節欄。
	///
	/// - Parameter announcesProgress: true＝使用者要求的重載（帶進行中訊號、不略過）；
	///   false＝背景輪詢。
	private func reload(announcesProgress: Bool) async {
		// 輪詢不排隊：往返沒有逾時也不可取消（見 ``DaemonSessionQuerier``）。輪詢迴圈自身是
		// 循序的（等這次回來才睡下一拍），會疊起來的是**另一條在飛的往返**——使用者按下的
		// 重載正卡在沒有回應的 daemon 上時，每拍再補一條，卡住的往返會一路佔住 socket I/O
		// 的執行緒。手動重載反過來**不受此限**：它是取不到資料時唯一的復原入口，略過它等同
		// 把按鈕停用。
		if !announcesProgress, roundTripsInFlight > 0 {
			// 被略過的拍要留下痕跡。daemon 接了連線卻不回應時這裡會一路略過，沒有訊號的話
			// 自動更新就靜靜停在原地、畫面上看起來卻一切正常——那比不更新更難察覺。
			//
			// - todo: 加「連續略過 ≥2 拍才升 `.stalled`」的門檻。現況對健康的手動重載也會誤報
			//   （幾百毫秒的往返仍可能撞上一拍），警告條進出還會擠動清單。
			backgroundIssue = .stalled
			return
		}
		roundTripsInFlight += 1
		defer { roundTripsInFlight -= 1 }
		libraryGeneration += 1
		let generation: Int = libraryGeneration
		if announcesProgress {
			// 已有清單就留在畫面上：打回 spinner 會丟掉捲動位置，也會讓細節欄一瞬間查不到摘要。
			if !hasLoadedSessions {
				libraryPhase = .loading
			}
			isReloading = true
			backgroundIssue = nil
		}
		// 只有最新那次重載能收掉旗標；被蓋過的那次回來時不動它。
		defer {
			if announcesProgress, generation == libraryGeneration {
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
			backgroundIssue = nil
			// 先執行再判斷：清選取有副作用，不放進短路條件裡（條件順序一調動就會被跳過）。
			let vanished: Bool = pruneSelectionIfVanished(from: result.sessions)
			guard !vanished, selectedSessionID != nil else {
				return
			}
			await loadDetail(announcesProgress: announcesProgress)
		} catch {
			guard generation == libraryGeneration else {
				return
			}
			let failure: DaemonFailure = .init(mapping: error, endpoint: resolveEndpoint())
			// 自動更新失敗時清單留在畫面上、只掛訊號——照細節欄那側的形狀（`.failed` 保留摘要
			// 只換說明）。daemon 重啟一次就把整份庫存清成錯誤頁，比顯示可能過期的清單更糟。
			// 手動重載，或連一份清單都還沒有時，才讓失敗接管畫面。
			guard !announcesProgress, hasLoadedSessions else {
				libraryPhase = .unavailable(failure)
				return
			}
			backgroundIssue = .failed(failure)
		}
	}

	/// - Parameter announcesProgress: false＝背景輪詢，資料已在畫面上、不打「更新中…」。
	private func loadDetail(announcesProgress: Bool) async {
		detailGeneration += 1
		let generation: Int = detailGeneration
		guard let id: String = selectedSessionID, let summary: SessionSummary = summary(for: id) else {
			detailPhase = .empty
			return
		}
		if announcesProgress {
			detailPhase = .loading(summary)
		}
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
