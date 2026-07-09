//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

// MARK: - NymphServerTests

private final class NymphServerTests {

	/// 短 socket 路徑（`sun_path` 上限 104；用 /tmp 避免 temp dir 過長）。
	private func temporarySocketURL() -> URL {
		URL(fileURLWithPath: "/tmp/nymph-\(UUID().uuidString.prefix(8)).sock")
	}

	/// 真 Unix socket 往返：client 送請求 → server 分派 → 回應解回；dispatcher 收到該請求。
	@Test
	private func `request round trips over unix socket`() async throws {
		let socketURL: URL = temporarySocketURL()
		let expected: NymphResponse = .ps(PsResult(sessions: []))
		let dispatcher: FakeDispatcher = .init(response: expected)
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: dispatcher)
		try server.start()
		defer { server.shutdown() }
		let client: NymphClient = .init(socketPath: socketURL)
		let response: NymphResponse = try await client.send(.ps(PsParams(all: true)))
		#expect(response == expected)
		#expect(dispatcher.received.current == [.ps(PsParams(all: true))])
	}

	/// tool-error 回應也能經 socket 原樣送回（envelope 過線）。
	@Test
	private func `tool error response round trips`() async throws {
		let socketURL: URL = temporarySocketURL()
		let expected: NymphResponse = .toolError(ToolError(code: "no_such_id", message: "no such session id: mfly-x"))
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: FakeDispatcher(response: expected))
		try server.start()
		defer { server.shutdown() }
		let response: NymphResponse = try await NymphClient(socketPath: socketURL).send(.status(StatusParams(id: "mfly-x")))
		#expect(response == expected)
	}

	/// isDaemonPresent：未起 false、起後 true、shutdown 後 false（NY-2 destroy 消歧的依據）。
	@Test
	private func `daemon presence tracks lifecycle`() async throws {
		let socketURL: URL = temporarySocketURL()
		#expect(NymphClient.isDaemonPresent(socketPath: socketURL) == false)
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: FakeDispatcher(response: .ps(PsResult(sessions: []))))
		try server.start()
		#expect(NymphClient.isDaemonPresent(socketPath: socketURL) == true)
		server.shutdown()
		#expect(NymphClient.isDaemonPresent(socketPath: socketURL) == false)
	}

	/// 連不上（daemon 未起）→ send 擲 connectFailed。
	@Test
	private func `send without daemon throws connect failed`() async {
		let socketURL: URL = temporarySocketURL()
		await #expect(throws: NymphTransportError.self) {
			try await NymphClient(socketPath: socketURL).send(.ps(PsParams()))
		}
	}
}
