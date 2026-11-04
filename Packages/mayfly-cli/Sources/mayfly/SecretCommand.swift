//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import MachineKit

/// `mayfly secret`：保管 guest 管理者密碼（`sudo` 用），值存在 keychain（見 ``KeychainGuestSecretStore``）。
///
/// - `set <alias>`：存入或覆寫。終端機上無回顯輸入兩次；stdin 不是終端機時讀 stdin（供管線匯入）。
/// - `rm <alias>`：刪除。
/// - `feed <alias> -- <command…>`：起一個本機命令，把密碼加一個換行寫進它的 stdin（給
///   `sudo -S`）。呼叫端只指定別名，值不經命令列、不經 shell 變數、不印到任何輸出。
///
/// 值從不寫到 stdout，紀錄也不含值。
internal struct SecretCommand: AsyncParsableCommand {

	/// 只掛子命令、自己不做事：沒給子命令時由 ArgumentParser 印說明。
	internal static let configuration: CommandConfiguration = .init(
		commandName: "secret",
		abstract: "Keep guest admin passwords (for sudo) in the keychain.",
		subcommands: [
			SecretSetCommand.self,
			SecretRemoveCommand.self,
			SecretFeedCommand.self
		]
	)
}
