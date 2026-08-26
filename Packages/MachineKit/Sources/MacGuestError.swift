//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// harness 層錯誤。VZ 層失敗除 keychain 診斷命中外原樣上拋 `VZError`。
public enum MacGuestError: Error {

	/// `start()` 已失敗（`VZErrorDomain` Code=1）且事後診斷發現 keychain
	/// 此刻不可用——把通用 internal error 翻成可修復的錯誤；underlying
	/// 保留原始 `VZError` 供上層記錄。
	case startBlockedByKeychain(underlying: any Error, keychain: KeychainPreflight.Status)
}
