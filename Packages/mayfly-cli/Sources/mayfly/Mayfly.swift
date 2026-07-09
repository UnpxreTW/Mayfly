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
/// **薄殼紀律**：編排單一正本在 MachineKit（``GuestSession`` / ``GuestCloner`` /
/// ``GuestLease``）與 nymph daemon 的 `SessionStore`，這層只做 argv 與 stdout / exit code
/// 的轉接。subcommand 依「是否需要 daemon」分兩組（設計 §7 / 契約 #31）：
///
/// - **standalone（無 daemon、直連引擎）**：`clone` / `run` / `ip` / `destroy <path>`——CI
///   custom-executor 的三段生命週期（prepare = clone + run + 等 READY、run = 呼叫端自行
///   SSH、cleanup = 結束 run 行程 + destroy）。
/// - **daemon client（連 socket）**：`spawn` / `exec <id>` / `ps` / `status <id>` /
///   `destroy <id>`——消費 nymph 的 session table。
/// - **起 daemon**：`nymph`（常駐、開 socket）。
///
/// `destroy` 過載依 socket 連通性消歧（NY-2、見 ``DestroyCommand``）。
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
			ExecCommand.self,
			PsCommand.self,
			StatusCommand.self
		]
	)
}
