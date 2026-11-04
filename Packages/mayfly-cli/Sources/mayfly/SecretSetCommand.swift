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

/// `mayfly secret set <alias>`。
internal struct SecretSetCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "set",
		abstract: "Store or replace the password for an alias.",
		discussion: """
		Prompts twice without echo when stdin is a terminal; otherwise reads stdin to EOF and \
		drops one trailing line break. The password is never accepted as an argument.
		"""
	)

	/// 別名。
	@Argument(help: "Alias, e.g. the golden alias the password belongs to.")
	internal var alias: String

	/// 儲存端選項。
	@OptionGroup
	internal var storeOptions: SecretStoreOptions

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 進入點：見型別說明。
	internal func run() async throws {
		guard GuestSecretAlias.isValid(alias) else {
			throw SecretCommandSupport.fail(GuestSecretStoreError.invalidAlias(alias))
		}
		let secret: Data
		do {
			secret = try SecretPrompt.read(alias: alias)
		} catch let problem as GuestSecretInput.Problem {
			throw SecretCommandSupport.fail(GuestSecretStoreError.invalidSecret(problem))
		}
		do {
			try await storeOptions.store.setSecret(secret, for: alias)
		} catch let error as GuestSecretStoreError {
			throw SecretCommandSupport.fail(error)
		}
		CommandOutput.logger.log(level: .info, "stored password for \(alias)")
	}
}
