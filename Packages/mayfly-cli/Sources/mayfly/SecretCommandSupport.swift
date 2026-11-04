//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import MachineKit

/// 三支子命令共用的錯誤收斂：記一行 error（不含值）＋ `ExitCode(1)`。
internal enum SecretCommandSupport {

	/// 儲存端錯誤 → 記一行 error + `ExitCode(1)`。
	/// - Parameter error: 儲存端錯誤。
	/// - Returns: 要擲出的退出碼。
	internal static func fail(_ error: GuestSecretStoreError) -> ExitCode {
		CommandOutput.logger.log(level: .error, "\(error.description)")
		return ExitCode(1)
	}
}
