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

/// `mayfly secret feed <alias> -- <command…>`。
internal struct SecretFeedCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "feed",
		abstract: "Run a local command with the password for an alias on its stdin.",
		discussion: """
		The command gets the password followed by one newline on stdin, then end of input, \
		which is what `sudo -S` expects. Its stdout and stderr pass through and its exit \
		status becomes this command's exit status. Example: \
		mayfly secret feed golden -- ssh admin@guest sudo -S softwareupdate --list
		"""
	)

	/// 別名。
	@Argument(help: "Alias.")
	internal var alias: String

	/// 要起的本機命令（經 `PATH` 找執行檔）。
	@Argument(parsing: .postTerminator, help: "Command and arguments, after `--`.")
	internal var command: [String] = []

	/// 儲存端選項。
	@OptionGroup
	internal var storeOptions: SecretStoreOptions

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 進入點：見型別說明。
	internal func run() async throws {
		guard !command.isEmpty else { throw ValidationError("feed requires a command after `--`.") }
		let secret: Data
		do {
			secret = try await storeOptions.store.secret(for: alias)
		} catch let error as GuestSecretStoreError {
			throw SecretCommandSupport.fail(error)
		}
		let status: Int32
		do {
			status = try await SecretFeeder.run(command, secret: secret)
		} catch {
			CommandOutput.logger.log(level: .error, "could not launch \(command[0]): \(error)")
			throw ExitCode(1)
		}
		throw ExitCode(status)
	}
}
