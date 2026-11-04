//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import MachineKit

/// 三支子命令共用的儲存端選項。
internal struct SecretStoreOptions: ParsableArguments {

	/// keychain 檔路徑；未給＝使用者的 default keychain。
	@Option(name: .customLong("keychain"), help: "Keychain file to use (default: the user's default keychain).")
	internal var keychain: String?

	/// 供 ArgumentParser 建構。
	internal init() {}

	/// 依選項組出儲存端。
	internal var store: KeychainGuestSecretStore {
		.init(keychain: keychain)
	}
}
