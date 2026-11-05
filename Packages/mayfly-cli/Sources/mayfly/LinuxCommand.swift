//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `mayfly linux`：Linux 容器映像的本機管理。
///
/// - `bake <alias> --base <base> --provision <script>`：從 base 映像起一台容器、跑設定腳本、把結果
///   固化成新映像並登記進別名表（見 ``LinuxBakeCommand``）。
///
/// standalone：不連 daemon、直接開容器。
internal struct LinuxCommand: AsyncParsableCommand {

	/// 只掛子命令、自己不做事：沒給子命令時由 ArgumentParser 印說明。
	internal static let configuration: CommandConfiguration = .init(
		commandName: "linux",
		abstract: "Manage Linux container images on this machine.",
		subcommands: [
			LinuxBakeCommand.self
		]
	)
}
