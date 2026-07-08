//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `mayfly` CLI 門面：ephemeral macOS VM 的 clone / run / ip / destroy。
///
/// **薄殼紀律**：編排單一正本在 MachineKit（``GuestSession`` / ``GuestCloner`` /
/// ``GuestLease``），這層只做 argv 與 stdout / exit code 的轉接——與未來的 MCP /
/// app 外殼消費同一套引擎 API。subcommand 集對齊 CI custom-executor 的三段
/// 生命週期：prepare（clone + run + 等 READY）、run（呼叫端自行 SSH）、
/// cleanup（結束 run 行程 + destroy）。
@main
struct Mayfly: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "mayfly",
		abstract: "Ephemeral macOS VMs on Apple Silicon (Virtualization.framework).",
		subcommands: [CloneCommand.self, RunCommand.self, IPCommand.self, DestroyCommand.self]
	)
}
