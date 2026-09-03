//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `mayfly` CLI 門面：ephemeral macOS VM 的兩用 binary。
///
/// **薄殼紀律**：編排單一正本在 MachineKit（``MacGuestSession`` / ``MacGuestCloner`` /
/// ``MacGuestLease``）與 nymph daemon 的 `SessionStore`，這層只做 argv 與 stdout / exit code
/// 的轉接。subcommand 依「是否需要 daemon」分兩組（設計 §7 / 契約 #31）：
///
/// - **standalone（無 daemon、直連引擎）**：`clone` / `run` / `ip` / `destroy <path>`——CI
///   custom-executor 的三段生命週期（prepare = clone + run + 等 READY、run = 呼叫端自行
///   SSH、cleanup = 結束 run 行程 + destroy）。
/// - **daemon client（連 socket）**：`spawn` / `execute <id>`（alias `exec`） /
///   `list`（alias `ps`） / `status <id>` / `destroy <id>`——消費 nymph 的 session table。
/// - **起 daemon**：`nymph`（常駐、開 socket）。
/// - **MCP shim**：`mcp`（短命 stdio 轉接殼、橋接同一顆 socket；契約 #31 步③，見
///   ``MCPCommand``）。
///
/// `destroy` 過載依 socket 連通性消歧（NY-2、見 ``DestroyCommand``）。
///
/// 輸出分兩面：要被讀走的資料走 stdout、紀錄走 stderr 的 `Logger`（見 ``CommandOutput``）。
@main
struct Mayfly: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "mayfly",
		abstract: "Ephemeral macOS VMs on Apple Silicon (Virtualization.framework).",
		subcommands: [
			CloneCommand.self,
			RunCommand.self,
			IPCommand.self,
			DestroyCommand.self,
			NymphCommand.self,
			SpawnCommand.self,
			ExecuteCommand.self,
			ListCommand.self,
			StatusCommand.self,
			MCPCommand.self
		]
	)

	/// 起手裝上紀錄後端，再把 argv 交給 ArgumentParser 的預設入口。
	///
	/// 後端只能裝一次、且要在第一行紀錄送出之前 ⇒ 落點是這支 binary 唯一的進入點。
	internal static func main() async {
		CommandOutput.bootstrap()
		await Self.main(nil)
	}
}
