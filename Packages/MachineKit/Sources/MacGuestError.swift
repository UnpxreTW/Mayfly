//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// harness 層錯誤。VZ 層失敗除 keychain 診斷命中外原樣上拋 `VZError`。
public enum MacGuestError: Error {

	/// preflight：login keychain 鎖定。macOS 15+ host 上 `start()` 會以
	/// 無線索的通用 Code=1 失敗，所以在碰 VZ 之前先擋下、給可修復的錯誤。
	case keychainLocked(path: String?)

	/// preflight：無 default keychain。
	case noDefaultKeychain

	/// `start()` 已失敗（`VZErrorDomain` Code=1）且二次診斷發現 keychain
	/// 此刻不可用——把通用 internal error 翻成可修復的錯誤；underlying
	/// 保留原始 `VZError` 供上層記錄。
	case startBlockedByKeychain(underlying: any Error, keychain: KeychainPreflight.Status)
}
