//
//  NymphMCPShim
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import MCP
import NymphKit

/// nymph 的 stdio MCP shim（契約 #31 步③）：把 ``NymphKit`` 的五工具（spawn / execute / list /
/// status / destroy）暴露成 MCP `tools/list` + `tools/call`、轉發到 nymph daemon 的 Unix
/// socket（``NymphClient``）。shim 本身**不含編排邏輯**——真正的 session 生命週期在 daemon 的
/// `SessionStore`；這裡只做 MCP ↔ socket 的協議轉接（``NymphToolCatalog`` 定 schema、
/// ``NymphToolInvoker`` 做轉接）。
///
/// `makeServer(client:)` 與 `run(client:)` 分開：前者回傳裝好 handler、尚未接 transport 的
/// `Server`，供測試接 `InMemoryTransport` 做真 MCP 握手（不真開 stdio pipe、不真開 VM）；後者
/// 是 `mayfly mcp` 子命令的生產路徑，接 stdio。
public enum NymphMCPServer {

	/// initialize 回應中的 server 名稱。
	public static let serverName = "mayfly-nymph"

	/// initialize 回應中的 server 版本（shim 自己的版號，非 daemon / MCP SDK 版號）。
	public static let serverVersion = "0.1.0"

	/// 組一個裝好五工具 handler 的 `Server`（尚未接 transport）。
	///
	/// - Parameter client: 送往 nymph daemon 的 socket client；預設連 ``NymphPaths/socketURL()``。
	public static func makeServer(client: NymphClient = .init()) async -> Server {
		let server: Server = .init(
			name: serverName,
			version: serverVersion,
			capabilities: .init(tools: .init(listChanged: false))
		)
		await server.withMethodHandler(ListTools.self) { _ in
			.init(tools: NymphToolCatalog.tools)
		}
		await server.withMethodHandler(CallTool.self) { params in
			await NymphToolInvoker.handle(params, client: client)
		}
		return server
	}

	/// 生產入口：`mayfly mcp` 子命令呼叫此函式——接 stdio、跑到對端斷線（EOF）收斂。daemon
	/// 不在跑不是致命錯誤：每個工具呼叫各自連線，連不上時該次呼叫回 tool-error（見
	/// ``NymphToolInvoker``），shim 行程本身不因此退出。
	public static func run(client: NymphClient = .init()) async throws {
		let server: Server = await makeServer(client: client)
		try await server.start(transport: StdioTransport())
		await server.waitUntilCompleted()
	}
}
