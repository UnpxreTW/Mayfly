//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import NymphMCPShim

/// `mayfly mcp`：起 stdio MCP shim（契約 #31 步③）——給 Claude Code / Desktop 這類只會
/// spawn stdio server 的 MCP client 用。橋接到 nymph daemon 的 Unix socket（複用
/// ``NymphClientSupport`` 同一顆 ``NymphClient``）；daemon 未起不是致命錯誤，個別工具呼叫會
/// 各自回 tool-error（見 `NymphToolInvoker`），不靜默自起 daemon（比照其餘 daemon-client 動詞）。
///
/// 與 `mayfly nymph`（常駐 daemon 本體、開 socket）分工：`nymph` 是長命 daemon、`mcp` 是短命
/// stdio 轉接殼，MCP client 每次連線各自 spawn 一個 `mcp` 行程。
struct MCPCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "mcp",
		abstract: "Run the stdio MCP shim, bridging an MCP client to the nymph daemon socket."
	)

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	func run() async throws {
		try await NymphMCPServer.run()
	}
}
