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

/// `mayfly secret rm <alias>`。
internal struct SecretRemoveCommand: AsyncParsableCommand {

	internal static let configuration: CommandConfiguration = .init(
		commandName: "rm",
		abstract: "Remove the password stored for an alias."
	)

	/// 別名。
	@Argument(help: "Alias.")
	internal var alias: String

	/// 儲存端選項。
	@OptionGroup
	internal var storeOptions: SecretStoreOptions

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	/// 進入點：見型別說明。
	internal func run() async throws {
		do {
			try await storeOptions.store.removeSecret(for: alias)
		} catch let error as GuestSecretStoreError {
			throw SecretCommandSupport.fail(error)
		}
		CommandOutput.logger.log(level: .info, "removed password for \(alias)")
	}
}
