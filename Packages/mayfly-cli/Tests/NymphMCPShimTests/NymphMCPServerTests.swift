//
//  NymphMCPShimTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import NymphKit
import Testing

@testable import NymphMCPShim

// MARK: - NymphMCPServerTests

/// 真 MCP 握手（initialize → tools/list → tools/call），走 `InMemoryTransport` 這對 in-process
/// pipe（不是真 stdio、不開子行程）；`Server` 背後接一顆指向真 Unix socket 的 ``NymphClient``、
/// socket 另一端是 `RecordingDispatcher`（不碰真 daemon / `SessionStore` / 真 VM）——驗的是
/// 「MCP 協議層 ↔ shim handler ↔ socket 協議層」整條路徑真的接得起來，非只有各段各自的單元。
private final class NymphMCPServerTests {

	/// 建一對已連的 `MCP.Client` / `NymphMCPServer`，`client` 已完成 initialize 握手。
	private func connectedClient(response: NymphResponse) async throws -> (client: Client, nymphServer: NymphServer, socketURL: URL) {
		let socketURL: URL = temporarySocketURL()
		let dispatcher: RecordingDispatcher = .init(response: response)
		let nymphServer: NymphServer = .init(socketPath: socketURL, dispatcher: dispatcher)
		try nymphServer.start()

		let mcpServer: Server = await NymphMCPServer.makeServer(client: NymphClient(socketPath: socketURL))
		let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
		try await mcpServer.start(transport: serverTransport)

		let client: Client = .init(name: "test-client", version: "0.0.0")
		_ = try await client.connect(transport: clientTransport)

		return (client, nymphServer, socketURL)
	}

	/// initialize 握手成功後，`tools/list` 回契約 #31 的五工具（真經過 JSON-RPC 編解碼、非
	/// 直接呼叫 Swift 函式）。
	@Test
	private func `handshake then list tools returns the five contract tools`() async throws {
		let harness = try await connectedClient(response: .list(ListResult(sessions: [])))
		defer { harness.nymphServer.shutdown() }

		let (tools, _) = try await harness.client.listTools()
		#expect(tools.map(\.name) == ["spawn", "execute", "list", "status", "destroy"])
	}

	/// `tools/call` 走完整條路徑：MCP client → in-memory transport → `Server` → `CallTool`
	/// handler → `NymphToolInvoker` → 真 socket → `RecordingDispatcher`——回應原樣繞回。
	@Test
	private func `tools call list round trips through the full stack`() async throws {
		let summary: SessionSummary = .init(id: "mfly-9", state: .ready, ip: "10.0.0.9", golden: "sequoia-base", cpus: 4, memoryGiB: 4, uptimeSeconds: 5)
		let harness = try await connectedClient(response: .list(ListResult(sessions: [summary])))
		defer { harness.nymphServer.shutdown() }

		let (content, isError) = try await harness.client.callTool(name: "list", arguments: ["all": false])
		#expect(isError == false)
		guard case let .text(text, _, _) = content.first else {
			Issue.record("expected a text content block")
			return
		}
		#expect(text.contains("mfly-9"))
		#expect(text.contains("10.0.0.9"))
	}

	/// 未知工具名經完整 MCP round trip 仍回 `isError == true`（非協議層例外、client 端不會看到
	/// 抛錯）。
	@Test
	private func `tools call unknown tool round trips as an error result`() async throws {
		let harness = try await connectedClient(response: .list(ListResult(sessions: [])))
		defer { harness.nymphServer.shutdown() }

		let (_, isError) = try await harness.client.callTool(name: "nuke", arguments: [:])
		#expect(isError == true)
	}
}
