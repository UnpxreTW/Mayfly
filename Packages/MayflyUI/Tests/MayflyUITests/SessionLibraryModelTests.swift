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

// MARK: - SessionLibraryModelTests

@MainActor
private final class SessionLibraryModelTests {

	/// 成功往返後清單原樣進 `loaded`。
	@Test
	private func `refresh publishes the sessions the daemon returns`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		#expect(model.libraryPhase == .loaded([SessionFixtures.sessionA]))
	}

	/// library 視角恆含已停止者——旗標寫反時畫面會少掉剛停下的 session 與它的停止原因。
	@Test
	private func `refresh always asks for stopped sessions too`() async {
		let fake: FakeSessionQuerier = .init()
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		await model.refresh()
		#expect(await fake.listCalls == [true])
	}

	/// 空表是正常態、不是錯誤（誤判成錯誤會讓乾淨的機器一開 app 就滿屏警告）。
	@Test
	private func `an empty session list is a loaded state, not a failure`() async {
		let model: SessionLibraryModel = SessionFixtures.model(querier: FakeSessionQuerier())
		await model.refresh()
		#expect(model.libraryPhase == .loaded([]))
	}

	/// socket 檔不在時的說明必須講清楚「這不代表沒有 daemon 在跑」——兩款措辭接反就等於
	/// 對使用者說謊。
	@Test
	private func `a transport failure without a socket file explains the launchd caveat`() async {
		let model: SessionLibraryModel = SessionFixtures.model(
			querier: FakeSessionQuerier(list: .failure(NymphTransportError.connectFailed("/tmp/x", "denied"))),
			endpoint: SessionFixtures.endpoint(socketPresent: false)
		)
		await model.refresh()
		let guidance: String? = SessionFixtures.failure(in: model.libraryPhase)?.guidance
		#expect(guidance?.contains(NymphPaths.stateDirectoryEnvironmentKey) == true)
		#expect(guidance?.contains("不代表沒有 daemon 在跑") == true)
	}

	/// socket 檔在卻連不上＝殘檔，另一款措辭。
	@Test
	private func `a failed connection with a socket file present reports a stale socket`() async {
		let model: SessionLibraryModel = SessionFixtures.model(
			querier: FakeSessionQuerier(
				list: .failure(NymphTransportError.connectFailed("/tmp/x", "connection refused"))
			),
			endpoint: SessionFixtures.endpoint(socketPresent: true)
		)
		await model.refresh()
		#expect(SessionFixtures.failure(in: model.libraryPhase)?.guidance.contains("殘檔") == true)
	}

	/// 連上之後才斷線代表那頭真的有 daemon——說成「殘檔」會把該被看見的 daemon 問題導向錯誤方向。
	@Test
	private func `a closed connection is reported as interrupted, not as a missing daemon`() async {
		let model: SessionLibraryModel = SessionFixtures.model(
			querier: FakeSessionQuerier(list: .failure(NymphTransportError.connectionClosed)),
			endpoint: SessionFixtures.endpoint(socketPresent: true)
		)
		await model.refresh()
		#expect(
			SessionFixtures.failure(in: model.libraryPhase)
				== .interrupted(detail: NymphTransportError.connectionClosed.description)
		)
	}

	/// 連都還沒連上的傳輸錯誤（路徑過長、建不出 socket）要留在「連不上」——講成連線中斷
	/// 會把設定問題導向「daemon 掛了」；而且原因要帶著走，落點說明救不了設定錯誤。
	@Test
	private func `a failure before the connection is attempted stays unreachable`() async {
		let error: NymphTransportError = .pathTooLong("/too/long")
		let endpoint: DaemonEndpoint = SessionFixtures.endpoint(socketPresent: false)
		let model: SessionLibraryModel = SessionFixtures.model(
			querier: FakeSessionQuerier(list: .failure(error)),
			endpoint: endpoint
		)
		await model.refresh()
		let failure: DaemonFailure? = SessionFixtures.failure(in: model.libraryPhase)
		#expect(failure == .unreachable(endpoint: endpoint, detail: error.description))
		#expect(failure?.guidance.contains(error.description) == true)
	}

	/// 只有最新那次重載能收掉進行中旗標——早發的那次先回來就收掉，spinner 會在還在飛時消失。
	@Test
	private func `only the newest reload clears the progress flag`() async {
		let fake: FakeSessionQuerier = .init()
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		let stale: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#1")
		await fake.gate("list#2")
		let newest: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#2")
		await fake.openGate("list#1")
		await stale.value
		#expect(model.isReloading)
		await fake.openGate("list#2")
		await newest.value
		#expect(!model.isReloading)
	}

	/// 重載期間要有進行中訊號：清單留在畫面上時，沒有它就看不出點擊生效了沒。
	@Test
	private func `reloading is reported while the round trip is in flight`() async {
		let fake: FakeSessionQuerier = .init()
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		let reload: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#1")
		#expect(model.isReloading)
		await fake.openGate("list#1")
		await reload.value
		#expect(!model.isReloading)
	}

	/// tool-error 的穩定 code 要原樣留著（畫面之外還有人靠它判別）。
	@Test
	private func `a tool error keeps its stable code`() async {
		let error: ToolError = .init(code: "admission_denied", message: "limit reached")
		let model: SessionLibraryModel = SessionFixtures.model(querier: FakeSessionQuerier(list: .failure(error)))
		await model.refresh()
		#expect(SessionFixtures.failure(in: model.libraryPhase) == .tool(code: "admission_denied", message: "limit reached"))
	}

	/// 動詞對不上＝協議落差，不混進「連不上」。
	@Test
	private func `an unmatched response converges to a protocol mismatch`() async {
		let model: SessionLibraryModel = SessionFixtures.model(
			querier: FakeSessionQuerier(list: .failure(UnexpectedDaemonResponse()))
		)
		await model.refresh()
		#expect(SessionFixtures.failure(in: model.libraryPhase) == .protocolMismatch)
	}

	/// 較早發出的重載回來時不得蓋掉較晚那次的結果。
	@Test
	private func `an outdated refresh cannot clobber a newer one`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.enqueueList(.success(ListResult(sessions: [SessionFixtures.sessionB])))
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake)
		let stale: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#1")
		await model.refresh()
		await fake.openGate("list#1")
		await stale.value
		#expect(model.libraryPhase == .loaded([SessionFixtures.sessionB]))
	}
}
