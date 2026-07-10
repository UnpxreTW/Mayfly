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

// MARK: - NymphToolInvokerTests

private final class NymphToolInvokerTests {

	/// 起一個真 socket 上的 `NymphServer`（`RecordingDispatcher` 背後）+ 對應 `NymphClient`；
	/// 呼叫端 `defer { server.shutdown() }`。
	private func makeHarness(response: NymphResponse) -> (client: NymphClient, dispatcher: RecordingDispatcher, server: NymphServer) {
		let socketURL: URL = temporarySocketURL()
		let dispatcher: RecordingDispatcher = .init(response: response)
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: dispatcher)
		try? server.start()
		return (NymphClient(socketPath: socketURL), dispatcher, server)
	}

	// MARK: spawn

	/// spawn 成功：參數原樣映成 ``SpawnParams``；結果 `structuredContent` 帶契約 #31 形狀
	/// `{ id, state, ip }`。
	@Test
	private func `spawn maps arguments and success result`() async throws {
		let expected: SpawnResult = .init(id: "mfly-abc123", state: .ready, ip: "10.0.0.9")
		let harness = makeHarness(response: .spawn(expected))
		defer { harness.server.shutdown() }

		let params: CallTool.Parameters = .init(name: "spawn", arguments: [
			"golden": "sequoia-base",
			"cpus": 8,
			"memory_gib": 6,
			"wait": false,
			"readiness_timeout_s": 60,
		])
		let result: CallTool.Result = await NymphToolInvoker.handle(params, client: harness.client)

		#expect(result.isError == false)
		#expect(result.structuredContent == [
			"id": "mfly-abc123",
			"state": "ready",
			"ip": "10.0.0.9",
		])
		let sent: [NymphRequest] = await harness.dispatcher.received
		#expect(sent == [.spawn(SpawnParams(golden: "sequoia-base", cpus: 8, memoryGiB: 6, wait: false, readinessTimeoutSeconds: 60))])
	}

	/// spawn 缺必填 `golden` → tool-error（`invalid_arguments`），連 daemon 都不連（無 socket
	/// harness）。
	@Test
	private func `spawn without golden is a tool error before reaching the daemon`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "spawn", arguments: [:]), client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "invalid_arguments")
	}

	/// booting 逾時降級：`ip` 為 nil → JSON `null`（NY-1）。
	@Test
	private func `spawn booting result encodes null ip`() async throws {
		let harness = makeHarness(response: .spawn(SpawnResult(id: "mfly-boot", state: .booting, ip: nil)))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "spawn", arguments: ["golden": "focal"]), client: harness.client)
		#expect(result.structuredContent == ["id": "mfly-boot", "state": "booting", "ip": nil])
	}

	// MARK: execute

	/// execute 成功：`exit` 非零仍是資料（`isError == false`）；cmd/env 陣列與字典原樣過線。
	@Test
	private func `execute non zero exit is data not a tool error`() async throws {
		let expected: ExecuteResult = .init(standardOutput: "boom\n", standardError: "trace\n", exit: 7)
		let harness = makeHarness(response: .execute(expected))
		defer { harness.server.shutdown() }

		let params: CallTool.Parameters = .init(name: "execute", arguments: [
			"id": "mfly-abc123",
			"cmd": ["swift", "test"],
			"timeout_s": 30,
			"cwd": "/tmp/work",
			"env": ["CI": "1"],
		])
		let result: CallTool.Result = await NymphToolInvoker.handle(params, client: harness.client)

		#expect(result.isError == false)
		#expect(result.structuredContent == ["stdout": "boom\n", "stderr": "trace\n", "exit": 7])
		let sent: [NymphRequest] = await harness.dispatcher.received
		#expect(sent == [.execute(ExecuteParams(
			id: "mfly-abc123",
			command: ["swift", "test"],
			timeoutSeconds: 30,
			standardInput: nil,
			workingDirectory: "/tmp/work",
			environment: ["CI": "1"]
		))])
	}

	/// execute 缺 `cmd`（或空陣列）→ tool-error，不送進 daemon。
	@Test
	private func `execute without cmd is a tool error`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "execute", arguments: ["id": "mfly-x"]), client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "invalid_arguments")
	}

	// MARK: list / status / destroy

	/// list：`all` 透傳；`sessions` 陣列映成契約形狀（不含 host 路徑）。
	@Test
	private func `list maps sessions to contract shape`() async throws {
		let summary: SessionSummary = .init(id: "mfly-1", state: .ready, ip: "10.0.0.5", golden: "sequoia-base", cpus: 4, memoryGiB: 4, uptimeSeconds: 42)
		let harness = makeHarness(response: .list(ListResult(sessions: [summary])))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "list", arguments: ["all": true]), client: harness.client)

		#expect(result.structuredContent == ["sessions": [[
			"id": "mfly-1", "state": "ready", "ip": "10.0.0.5", "golden": "sequoia-base",
			"cpus": 4, "memory_gib": 4, "uptime_s": 42,
		]]])
		let sent: [NymphRequest] = await harness.dispatcher.received
		#expect(sent == [.list(ListParams(all: true))])
	}

	/// status：帶 `stop_reason`。
	@Test
	private func `status includes stop reason`() async throws {
		let summary: SessionSummary = .init(id: "mfly-2", state: .stopped, ip: nil, golden: "sequoia-base", cpus: 4, memoryGiB: 4, uptimeSeconds: 99)
		let harness = makeHarness(response: .status(StatusResult(summary: summary, stopReason: "guest")))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "status", arguments: ["id": "mfly-2"]), client: harness.client)

		#expect(result.structuredContent == [
			"id": "mfly-2", "state": "stopped", "ip": nil, "golden": "sequoia-base",
			"cpus": 4, "memory_gib": 4, "uptime_s": 99, "stop_reason": "guest",
		])
	}

	/// destroy：`force` 預設 true、透傳；成功回 `{ id, destroyed: true }`。
	@Test
	private func `destroy defaults force to true`() async throws {
		let harness = makeHarness(response: .destroy(DestroyResult(id: "mfly-3", destroyed: true)))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "destroy", arguments: ["id": "mfly-3"]), client: harness.client)

		#expect(result.structuredContent == ["id": "mfly-3", "destroyed": true])
		let sent: [NymphRequest] = await harness.dispatcher.received
		#expect(sent == [.destroy(DestroyParams(id: "mfly-3", force: true))])
	}

	// MARK: error mapping

	/// daemon 的 tool-error（``ToolError``）：穩定 `code` 原樣過線、`isError == true`；`message`
	/// 換成 shim 依 code 對映的**通稱化訊息**（不透傳 daemon 原始 message）。
	@Test
	private func `daemon tool error maps to isError result`() async throws {
		let harness = makeHarness(response: .toolError(ToolError(code: "no_such_id", message: "no such session id: mfly-x")))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "status", arguments: ["id": "mfly-x"]), client: harness.client)

		#expect(result.isError == true)
		#expect(result.structuredContent == ["code": "no_such_id", "message": "no session with the requested id"])
	}

	/// daemon 原始訊息夾帶 host 絕對路徑（`clone_failed` 帶 `clone failed: <path>`）時，shim
	/// **只放行通稱化訊息**——對外整份 `CallTool.Result`（`content` 人讀文字 + `structuredContent`
	/// 機器可讀）序列化後**都不含**該 host 路徑，`code` 仍原樣 actionable。
	@Test
	private func `daemon error host path never leaks to the client`() async throws {
		let secretPath = "/Users/aron/GoldenBundles/sequoia-base.bundle"
		let harness = makeHarness(response: .toolError(ToolError(code: "clone_failed", message: "clone failed: \(secretPath)")))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "spawn", arguments: ["golden": "sequoia-base"]), client: harness.client)

		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "clone_failed")
		#expect(result.structuredContent?.objectValue?["message"] == "failed to clone the golden bundle")
		let serialized: String = try encodedResultText(result)
		#expect(serialized.contains(secretPath) == false)
		#expect(serialized.contains("/Users/") == false)
	}

	/// daemon `transport_failure` 原始訊息夾帶 guest IP / ssh stderr 時，shim 通稱化——對外整份
	/// 結果不含 guest IP。
	@Test
	private func `daemon transport failure hides guest ip`() async throws {
		let guestIP = "10.0.7.42"
		let harness = makeHarness(response: .toolError(ToolError(code: "transport_failure", message: "ssh transport failure: connect to host \(guestIP): Connection refused")))
		defer { harness.server.shutdown() }
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "execute", arguments: ["id": "mfly-x", "cmd": ["ls"]]), client: harness.client)

		#expect(result.structuredContent?.objectValue?["code"] == "transport_failure")
		#expect(result.structuredContent?.objectValue?["message"] == "the SSH connection to the guest failed")
		let serialized: String = try encodedResultText(result)
		#expect(serialized.contains(guestIP) == false)
	}

	/// 傳輸層 `pathTooLong` 對外訊息**不帶 socket 路徑值**——過長 socket 路徑本身就是 host 路徑，
	/// 不得外流；映成 `daemon_unreachable` + 通稱訊息。
	@Test
	private func `path too long does not leak the socket path`() async {
		let longPath = "/tmp/nymph-" + String(repeating: "x", count: 160) + ".sock"
		let client: NymphClient = .init(socketPath: URL(fileURLWithPath: longPath))
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "list", arguments: [:]), client: client)

		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "daemon_unreachable")
		let message: String? = result.structuredContent?.objectValue?["message"]?.stringValue
		#expect(message?.contains(longPath) == false)
		#expect(message?.contains("/tmp/") == false)
	}

	/// 未知工具名 → tool-error `unknown_tool`（不是協議層 methodNotFound——`CallTool` handler
	/// 內部分派，非 MCP method 路由）。
	@Test
	private func `unknown tool name is a tool error`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "nuke", arguments: [:]), client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "unknown_tool")
	}

	/// daemon 不在跑（socket 沒有 listener）→ 傳輸失敗映成 `daemon_unreachable` tool-error，
	/// 不擲例外、不崩 shim。
	@Test
	private func `daemon unreachable maps to tool error`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let result: CallTool.Result = await NymphToolInvoker.handle(.init(name: "list", arguments: [:]), client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "daemon_unreachable")
	}

	// MARK: argument validation

	/// `cmd` 陣列含**非字串元素**（`["swift", 42]`）→ `invalid_arguments` tool-error，且**不送進**
	/// daemon（不 `compactMap` 靜默丟棄、無聲改寫 argv）。
	@Test
	private func `execute cmd with a non string element is a tool error`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let params: CallTool.Parameters = .init(name: "execute", arguments: ["id": "mfly-x", "cmd": ["swift", 42, "test"]])
		let result: CallTool.Result = await NymphToolInvoker.handle(params, client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "invalid_arguments")
	}

	/// 選填純量的**字串編碼**值以寬鬆轉型接受——`wait: "false"` → `false`、`memory_gib: "8"` → `8`
	/// （不再無聲吞成預設 true / 4），原樣過線進 daemon。
	@Test
	private func `string encoded scalars are coerced not swallowed`() async throws {
		let harness = makeHarness(response: .spawn(SpawnResult(id: "mfly-x", state: .booting, ip: nil)))
		defer { harness.server.shutdown() }
		let params: CallTool.Parameters = .init(name: "spawn", arguments: [
			"golden": "sequoia-base",
			"wait": "false",
			"memory_gib": "8",
		])
		_ = await NymphToolInvoker.handle(params, client: harness.client)
		let sent: [NymphRequest] = await harness.dispatcher.received
		#expect(sent == [.spawn(SpawnParams(golden: "sequoia-base", cpus: 4, memoryGiB: 8, wait: false, readinessTimeoutSeconds: 180))])
	}

	/// 選填純量存在但**無法轉型**（`memory_gib: "abc"`）→ `invalid_arguments` tool-error，不靜默
	/// 吞成預設（明示值被無聲忽略是 bug）。
	@Test
	private func `unparseable scalar is a tool error not a default`() async {
		let client: NymphClient = .init(socketPath: temporarySocketURL())
		let params: CallTool.Parameters = .init(name: "spawn", arguments: ["golden": "sequoia-base", "memory_gib": "abc"])
		let result: CallTool.Result = await NymphToolInvoker.handle(params, client: client)
		#expect(result.isError == true)
		#expect(result.structuredContent?.objectValue?["code"] == "invalid_arguments")
	}

	// MARK: helpers

	/// 把整份 ``CallTool/Result``（`content` 人讀文字 + `structuredContent` + 旗標）序列化成 JSON
	/// 文字，供「敏感字串完全不外流」的斷言逐字掃描。
	private func encodedResultText(_ result: CallTool.Result) throws -> String {
		let data: Data = try JSONEncoder().encode(result)
		return String(data: data, encoding: .utf8) ?? ""
	}
}
