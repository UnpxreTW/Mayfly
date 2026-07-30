//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

@testable import MayflyUI

// MARK: - SessionDetailPhaseTests

@MainActor
private final class SessionDetailPhaseTests {

	/// 選取後細節欄拿到完整狀態（含只有 status 才有的停止原因）。
	@Test
	private func `selecting a session loads its status including the stop reason`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		let status: StatusResult = .init(summary: SessionFixtures.sessionA, stopReason: "guest")
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(status))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		#expect(model.detailPhase == .loaded(status))
	}

	/// 換選取之後，前一個選取的回應回來時要丟掉。
	@Test
	private func `a status response for a superseded selection is discarded`() async {
		let sessions: [SessionSummary] = [SessionFixtures.sessionA, SessionFixtures.sessionB]
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: sessions)))
		let statusA: StatusResult = .init(summary: SessionFixtures.sessionA)
		let statusB: StatusResult = .init(summary: SessionFixtures.sessionB)
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(statusA))
		await fake.setStatus(id: SessionFixtures.sessionB.id, .success(statusB))
		await fake.gate("status#1:\(SessionFixtures.sessionA.id)")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		let stale: Task<Void, Never> = Task { await model.loadDetail() }
		await fake.waitForCall("status#1:\(SessionFixtures.sessionA.id)")
		model.selectedSessionID = SessionFixtures.sessionB.id
		await model.loadDetail()
		await fake.openGate("status#1:\(SessionFixtures.sessionA.id)")
		await stale.value
		#expect(model.detailPhase == .loaded(statusB))
	}

	/// status 失敗只影響細節欄，清單留著（session 可能只是剛被回收）。
	@Test
	private func `a status failure keeps the library and marks only the detail failed`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		let error: ToolError = .init(code: "no_such_id", message: "no such session id: \(SessionFixtures.sessionA.id)")
		await fake.setStatus(id: SessionFixtures.sessionA.id, .failure(error))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		#expect(model.libraryPhase == .loaded([SessionFixtures.sessionA]))
		#expect(
			model.detailPhase == .failed(SessionFixtures.sessionA, .tool(code: "no_such_id", message: error.message))
		)
	}

	/// 選取的 session 從清單消失時，選取與細節欄一起清掉。
	@Test
	private func `refresh clears a selection that vanished from the list`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(StatusResult(summary: SessionFixtures.sessionA)))
		await fake.enqueueList(.success(ListResult(sessions: [])))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		await model.refresh()
		#expect(model.selectedSessionID == nil)
		#expect(model.detailPhase == .empty)
	}

	/// 重新載入要連細節欄一起更新——只更新半個畫面時，左列顯示就緒、右欄還停在開機中。
	@Test
	private func `refresh also reloads the selected session detail`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(StatusResult(summary: SessionFixtures.sessionA)))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		let settled: StatusResult = .init(summary: SessionFixtures.sessionA, stopReason: "guest")
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(settled))
		await model.refresh()
		#expect(model.detailPhase == .loaded(settled))
	}

	/// 重載時細節欄要用**新清單**那份摘要——`loadDetail()` 一旦被移到清單更新之前就會讀到舊的。
	@Test
	private func `the reloaded detail is built from the newest summary`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.enqueueList(.success(ListResult(sessions: [SessionFixtures.sessionAAdvanced])))
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(StatusResult(summary: SessionFixtures.sessionA)))
		await fake.gate("status#2:\(SessionFixtures.sessionA.id)")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		let reload: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("status#2:\(SessionFixtures.sessionA.id)")
		#expect(model.detailPhase == .loading(SessionFixtures.sessionAAdvanced))
		await fake.openGate("status#2:\(SessionFixtures.sessionA.id)")
		await reload.value
	}

	/// session 在狀態查詢途中從清單消失：回來的舊資料不得寫回已清空的細節欄。
	@Test
	private func `an in-flight status is discarded when its session vanishes`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(StatusResult(summary: SessionFixtures.sessionA)))
		await fake.enqueueList(.success(ListResult(sessions: [])))
		await fake.gate("status#1:\(SessionFixtures.sessionA.id)")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		let stale: Task<Void, Never> = Task { await model.loadDetail() }
		await fake.waitForCall("status#1:\(SessionFixtures.sessionA.id)")
		await model.refresh()
		await fake.openGate("status#1:\(SessionFixtures.sessionA.id)")
		await stale.value
		#expect(model.selectedSessionID == nil)
		#expect(model.detailPhase == .empty)
	}

	/// 取消選取即清空細節欄。
	@Test
	private func `clearing the selection empties the detail`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(StatusResult(summary: SessionFixtures.sessionA)))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		model.selectedSessionID = nil
		await model.loadDetail()
		#expect(model.detailPhase == .empty)
	}
}
