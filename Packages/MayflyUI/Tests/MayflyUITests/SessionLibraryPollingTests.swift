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

// MARK: - SessionLibraryPollingTests

/// 自動輪詢的行為：會反覆跑、取消就停、不打擾使用者、不堆疊往返，出事時說得出來。
///
/// 本檔的等待一律有上限（`waitForCall` 與 `waitUntil`），逾時即記 issue：迴圈若回歸成只跑
/// 一次，要得到紅字而不是掛住整個 CI。`.timeLimit` 只當第二道防線——**實測它擋不住非取消
/// 感知的等待**（時限到時它記下 issue，但測試行程仍不會結束）。
@MainActor
private final class SessionLibraryPollingTests {

	/// 迴圈要持續發下一次往返——只跑開場那一次的話，畫面上的狀態從此不再更新。
	///
	/// 判定落在 `waitForCall("list#3")` 上——它等不到就自己記 issue，因此這條的失敗機制是
	/// 那個上限，而非底下那句必然成立的 `#expect`。
	@Test(.timeLimit(.minutes(1)))
	private func `polling keeps issuing round trips`() async {
		let fake: FakeSessionQuerier = .init()
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await fake.waitForCall("list#3")
		poll.cancel()
		await poll.value
		#expect(await fake.listCalls.count >= 3)
	}

	/// 取消即停：畫面離場後還在打 daemon 等於背景多了一條沒人看的流量。
	///
	/// 間隔取得遠長於測試壽命，迴圈能收束就只可能是取消所致；`await poll.value` 是關鍵——
	/// 沒有它只證明「發過取消」，證明不了迴圈真的退出來了。
	@Test(.timeLimit(.minutes(1)))
	private func `a cancelled poll task stops before the next tick`() async {
		let fake: FakeSessionQuerier = .init()
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .seconds(600))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await fake.waitForCall("list#1")
		poll.cancel()
		await poll.value
		#expect(await fake.listCalls == [true])
	}

	/// 輪詢不亮進行中訊號：每兩秒閃一次的 spinner 會讓使用者分不出那是自動更新還是自己按的鈕。
	@Test(.timeLimit(.minutes(1)))
	private func `polling does not raise the manual reload signal`() async {
		let fake: FakeSessionQuerier = .init()
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await fake.waitForCall("list#1")
		#expect(!model.isReloading)
		await fake.openGate("list#1")
		poll.cancel()
		await poll.value
	}

	/// 輪詢也不打「更新中…」：細節欄的資料已在畫面上，每拍閃一次註記只是雜訊。
	@Test(.timeLimit(.minutes(1)))
	private func `polling refreshes the detail without flagging it as updating`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		let first: StatusResult = .init(summary: SessionFixtures.sessionA)
		await fake.setStatus(id: SessionFixtures.sessionA.id, .success(first))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		await model.refresh()
		model.selectedSessionID = SessionFixtures.sessionA.id
		await model.loadDetail()
		#expect(model.detailPhase == .loaded(first))
		// 攔下輪詢發出的那次狀態查詢，看它在途時細節欄長什麼樣。
		await fake.gate("status#2:\(SessionFixtures.sessionA.id)")
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await fake.waitForCall("status#2:\(SessionFixtures.sessionA.id)")
		#expect(model.detailPhase == .loaded(first))
		await fake.openGate("status#2:\(SessionFixtures.sessionA.id)")
		poll.cancel()
		await poll.value
	}

	/// 使用者按下的重載卡在沒有回應的 daemon 上時，輪詢不准往上疊——往返沒有逾時也不可取消，
	/// 每拍補一條就是每拍多佔一條 socket I/O 的執行緒。
	///
	/// 迴圈自身循序，所以會疊起來的只可能是這條路徑。
	@Test(.timeLimit(.minutes(1)))
	private func `polling does not stack round trips on top of a stuck manual reload`() async {
		let fake: FakeSessionQuerier = .init()
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let manual: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#1")
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		// 等迴圈確實跑過數拍再數往返。改成睡固定一段時間的話，機器一忙就一拍都沒跑，
		// 「仍然只有一次呼叫」會變成恆真的假綠。
		await waitUntil("輪詢跑過三拍") { model.pollTicks >= 3 }
		// 先取值再斷言：`#expect` 對含 `await` 的運算式印不出實際值，失敗時會只留「不成立」。
		let calls: [Bool] = await fake.listCalls
		#expect(calls.count == 1)
		// 略過的拍不能無聲無息——這是使用者唯一看得到「自動更新停住了」的訊號。
		#expect(model.backgroundIssue == .stalled)
		await fake.openGate("list#1")
		await manual.value
		poll.cancel()
		await poll.value
	}

	/// 手動重載**不受**上一條的節流影響：daemon 接了連線卻不回應時，那顆按鈕是唯一的復原
	/// 入口，略過它等同把它停用——正是先前刻意不做的事。
	@Test(.timeLimit(.minutes(1)))
	private func `a manual reload is never skipped by an in-flight round trip`() async {
		let fake: FakeSessionQuerier = .init()
		await fake.gate("list#1")
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .seconds(600))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await fake.waitForCall("list#1")
		await fake.gate("list#2")
		let manual: Task<Void, Never> = Task { await model.refresh() }
		await fake.waitForCall("list#2")
		#expect(model.isReloading)
		await fake.openGate("list#1")
		await fake.openGate("list#2")
		await manual.value
		poll.cancel()
		await poll.value
		#expect(!model.isReloading)
	}
}

// MARK: - SessionLibraryBackgroundIssueTests

/// 自動更新出事時的呈現：清單留著，但一定講得出「這份資料可能不是當下狀態」。
@MainActor
private final class SessionLibraryBackgroundIssueTests {

	/// 自動更新失敗不清畫面——daemon 重啟一次就把整份庫存換成錯誤頁，比顯示可能過期的清單更糟。
	@Test(.timeLimit(.minutes(1)))
	private func `a failed poll keeps the list on screen and says so`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.enqueueList(.failure(NymphTransportError.connectFailed("/tmp/x", "connection refused")))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await waitUntil("自動更新掛上異常訊號") { model.backgroundIssue != nil }
		poll.cancel()
		await poll.value
		#expect(model.libraryPhase == .loaded([SessionFixtures.sessionA]))
		guard case .failed = model.backgroundIssue else {
			Issue.record("自動更新失敗要留下 .failed 訊號，實得 \(String(describing: model.backgroundIssue))")
			return
		}
	}

	/// **空清單**也要拿得到訊號。乾淨機器上第一拍就是 `.loaded([])`，daemon 之後掛掉時若沒有
	/// 訊號，畫面會一直說「daemon 目前沒有任何 session」——那是最容易被當成事實的一句謊。
	///
	/// 畫面側對應的保證是說明條掛在 `SessionLibraryView` 的 `body` 上、不掛在任何一個相位分支
	/// 裡；那個掛法沒有單元測試的接縫（要靠 view 檢視類的依賴），此處釘的是 model 這一半。
	@Test(.timeLimit(.minutes(1)))
	private func `an empty list still gets a signal when the poll fails`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [])))
		await fake.enqueueList(.failure(NymphTransportError.connectFailed("/tmp/x", "connection refused")))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await waitUntil("空清單態也掛上異常訊號") { model.backgroundIssue != nil }
		poll.cancel()
		await poll.value
		#expect(model.libraryPhase == .loaded([]))
	}

	/// 一次瞬時失敗之後自己好起來，訊號要收掉——留著會變成永久的假警報。
	@Test(.timeLimit(.minutes(1)))
	private func `a recovered poll clears the background issue`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.enqueueList(.failure(NymphTransportError.connectionClosed))
		await fake.enqueueList(.success(ListResult(sessions: [SessionFixtures.sessionB])))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await waitUntil("自動更新掛上異常訊號") { model.backgroundIssue != nil }
		await waitUntil("下一拍成功後訊號收掉") { model.backgroundIssue == nil }
		poll.cancel()
		await poll.value
		#expect(model.libraryPhase == .loaded([SessionFixtures.sessionB]))
	}

	/// 連一份清單都還沒有時，失敗就該接管畫面——沒有東西可保留，藏起來只剩空白。
	@Test(.timeLimit(.minutes(1)))
	private func `a first poll that fails takes over the screen`() async {
		let error: NymphTransportError = .connectFailed("/tmp/x", "connection refused")
		let fake: FakeSessionQuerier = .init(list: .failure(error))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .seconds(600))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await waitUntil("第一拍寫回結果") { model.libraryPhase != .loading }
		poll.cancel()
		await poll.value
		#expect(SessionFixtures.failure(in: model.libraryPhase) != nil)
		#expect(model.backgroundIssue == nil)
	}

	/// 使用者按下重載＝畫面回到他手上，背景訊號當場收掉，不與新的進行中訊號並存。
	@Test(.timeLimit(.minutes(1)))
	private func `a manual reload clears the background issue on entry`() async {
		let fake: FakeSessionQuerier = .init(list: .success(ListResult(sessions: [SessionFixtures.sessionA])))
		await fake.enqueueList(.failure(NymphTransportError.connectionClosed))
		let model: SessionLibraryModel = SessionFixtures.model(querier: fake, pollInterval: .milliseconds(1))
		let poll: Task<Void, Never> = Task { await model.pollForever() }
		await waitUntil("自動更新掛上異常訊號") { model.backgroundIssue != nil }
		poll.cancel()
		await poll.value
		let manual: Task<Void, Never> = Task { await model.refresh() }
		await manual.value
		#expect(model.backgroundIssue == nil)
	}
}

// MARK: - Bounded waiting

/// 等條件成立，最多等 `timeout`；逾時記一條 issue 後返回、**不掛住**。
///
/// 沒有上限的等待會把回歸變成「掛住整個測試行程」而不是紅字。`.timeLimit` trait 補不上這個
/// 缺口——實測時限到時它會記下 issue，但停在非取消感知的等待上的測試仍不會結束。
@MainActor
private func waitUntil(
	_ description: String,
	timeout: Duration = .seconds(5),
	_ condition: () -> Bool
) async {
	let clock: ContinuousClock = .init()
	let deadline: ContinuousClock.Instant = clock.now.advanced(by: timeout)
	while clock.now < deadline {
		if condition() {
			return
		}
		try? await Task.sleep(for: .milliseconds(1))
		if Task.isCancelled {
			break
		}
	}
	if !condition() {
		Issue.record("等不到：\(description)（已等 \(timeout)）")
	}
}
