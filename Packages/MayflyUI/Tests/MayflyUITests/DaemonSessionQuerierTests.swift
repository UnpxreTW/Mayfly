//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit
import Testing

@testable import MayflyUI

// MARK: - DaemonSessionQuerierTests

/// 回應分支的判讀——加動詞時最容易抄錯的一段，靠注入式往返釘住。
private final class DaemonSessionQuerierTests {

	/// list 請求要帶著旗標送出去，回應原樣回傳。
	@Test
	private func `a list round trip carries the flag and returns the result`() async throws {
		let expected: ListResult = .init(sessions: [SessionFixtures.sessionA])
		let querier: DaemonSessionQuerier = .init { request in
			#expect(request == .list(ListParams(all: true)))
			return .list(expected)
		}
		#expect(try await querier.listSessions(includeStopped: true) == expected)
	}

	/// status 請求要帶著 id 送出去，回應原樣回傳（含停止原因）。
	@Test
	private func `a status round trip carries the id and returns the result`() async throws {
		let expected: StatusResult = .init(summary: SessionFixtures.sessionA, stopReason: "guest")
		let querier: DaemonSessionQuerier = .init { request in
			#expect(request == .status(StatusParams(id: SessionFixtures.sessionA.id)))
			return .status(expected)
		}
		#expect(try await querier.sessionStatus(id: SessionFixtures.sessionA.id) == expected)
	}

	/// tool-error 要擲給呼叫端判別，不可吞成空結果。
	@Test
	private func `a tool error is thrown to the caller`() async {
		let querier: DaemonSessionQuerier = .init { _ in
			.toolError(ToolError(code: "no_such_id", message: "no such session id"))
		}
		await #expect(throws: ToolError.self) {
			try await querier.sessionStatus(id: SessionFixtures.sessionA.id)
		}
	}

	/// 回應的動詞對不上請求＝協議落差，不可當成功。
	@Test
	private func `a response for another verb becomes an unmatched response`() async {
		let querier: DaemonSessionQuerier = .init { _ in
			.destroy(DestroyResult(id: SessionFixtures.sessionA.id))
		}
		await #expect(throws: UnexpectedDaemonResponse.self) {
			try await querier.listSessions(includeStopped: false)
		}
	}

	/// 兩個動詞各自都要驗完三個分支：抄錯最典型的形式就是新動詞漏抄其中一個。
	@Test
	private func `a tool error on list is thrown to the caller`() async {
		let querier: DaemonSessionQuerier = .init { _ in
			.toolError(ToolError(code: "internal_error", message: "listing failed"))
		}
		await #expect(throws: ToolError.self) {
			try await querier.listSessions(includeStopped: true)
		}
	}

	/// status 被別的動詞回應同樣是協議落差。
	@Test
	private func `a status request answered by another verb becomes an unmatched response`() async {
		let querier: DaemonSessionQuerier = .init { _ in
			.list(ListResult(sessions: []))
		}
		await #expect(throws: UnexpectedDaemonResponse.self) {
			try await querier.sessionStatus(id: SessionFixtures.sessionA.id)
		}
	}
}
