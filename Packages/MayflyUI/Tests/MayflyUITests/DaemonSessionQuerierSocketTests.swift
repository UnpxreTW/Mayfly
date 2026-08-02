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

// MARK: - DaemonSessionQuerierSocketTests

/// 走真 Unix domain socket 的整合測試：注入式往返測得到分支判讀，卻測不到「線本身接得起來」
/// ——編碼、換行分隔、連線收束、以及**端點的路徑有沒有真的被用上**都只有真連一次才知道。
private final class DaemonSessionQuerierSocketTests {

	/// 短路徑：`sun_path` 上限 104 bytes，temp dir 太長會綁不起來（先例同 `NymphServerTests`）。
	private func temporarySocketURL() -> URL {
		URL(fileURLWithPath: "/tmp/nymph-\(UUID().uuidString.prefix(8)).sock")
	}

	/// list 真的過線：請求送到伺服端、結果原樣解回。
	///
	/// 同時釘住「客戶端連的是 ``DaemonEndpoint`` 給的路徑」——若哪天改回讓 `NymphClient` 自己
	/// 解預設落點，這條會連不上而紅字，不會靜默分岔成兩個解析點。
	@Test
	private func `a list request round trips over a real unix socket`() async throws {
		let socketURL: URL = temporarySocketURL()
		let expected: ListResult = .init(sessions: [SessionFixtures.sessionA, SessionFixtures.sessionB])
		let dispatcher: FakeDispatcher = .init(response: .list(expected))
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: dispatcher)
		try server.start()
		defer { server.shutdown() }
		let querier: DaemonSessionQuerier = .init(
			endpoint: DaemonEndpoint(socketPath: socketURL.path, isSocketPresent: true)
		)
		#expect(try await querier.listSessions(includeStopped: true) == expected)
		#expect(await dispatcher.received == [.list(ListParams(all: true))])
	}

	/// status 同樣過線，且只有它帶得回停止原因。
	@Test
	private func `a status request round trips over a real unix socket`() async throws {
		let socketURL: URL = temporarySocketURL()
		let expected: StatusResult = .init(summary: SessionFixtures.sessionA, stopReason: "guest")
		let dispatcher: FakeDispatcher = .init(response: .status(expected))
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: dispatcher)
		try server.start()
		defer { server.shutdown() }
		let querier: DaemonSessionQuerier = .init(
			endpoint: DaemonEndpoint(socketPath: socketURL.path, isSocketPresent: true)
		)
		#expect(try await querier.sessionStatus(id: SessionFixtures.sessionA.id) == expected)
		#expect(await dispatcher.received == [.status(StatusParams(id: SessionFixtures.sessionA.id))])
	}

	/// 伺服端回錯動詞＝協議落差，過了線也一樣要擲。
	@Test
	private func `a mismatched verb over the socket becomes an unmatched response`() async throws {
		let socketURL: URL = temporarySocketURL()
		let server: NymphServer = .init(
			socketPath: socketURL,
			dispatcher: FakeDispatcher(response: .destroy(DestroyResult(id: SessionFixtures.sessionA.id)))
		)
		try server.start()
		defer { server.shutdown() }
		let querier: DaemonSessionQuerier = .init(
			endpoint: DaemonEndpoint(socketPath: socketURL.path, isSocketPresent: true)
		)
		await #expect(throws: UnexpectedDaemonResponse.self) {
			try await querier.listSessions(includeStopped: true)
		}
	}

	/// 沒有伺服端在聽時，真實的連線失敗要一路收斂成「連不上」——這條把傳輸層的實際錯誤
	/// （而非測試自己捏的那顆）接進畫面狀態。
	@MainActor
	@Test
	private func `a real connection failure surfaces as an unreachable library`() async {
		let socketURL: URL = temporarySocketURL()
		let endpoint: DaemonEndpoint = .init(socketPath: socketURL.path, isSocketPresent: false)
		let model: SessionLibraryModel = .init(
			querier: DaemonSessionQuerier(endpoint: endpoint),
			resolveEndpoint: { endpoint }
		)
		await model.refresh()
		#expect(model.libraryPhase == .unavailable(.unreachable(endpoint: endpoint, detail: nil)))
	}
}
