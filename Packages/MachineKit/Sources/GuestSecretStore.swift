//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// guest 管理者密碼（`sudo` 用）的保管處：依別名存、取、刪。
///
/// 值只在記憶體裡流動：存進安全儲存、取出後直接交給要它的行程 stdin，不落明文檔、不寫進
/// 紀錄。錯誤訊息不帶值。抽成協定是為了讓呼叫端（CLI、日後需要
/// `sudo` 的步驟）注入假實作單測。真實作見 ``KeychainGuestSecretStore``。
public protocol GuestSecretStore: Sendable {

	/// 存入（或覆寫）一個別名的密碼。
	/// - Parameters:
	///   - secret: 密碼位元組，須先過 ``GuestSecretInput/validate(_:)``。
	///   - alias: 別名，須符合 ``GuestSecretAlias/isValid(_:)``。
	/// - Throws: ``GuestSecretStoreError``。
	func setSecret(_ secret: Data, for alias: String) async throws

	/// 取出一個別名的密碼。
	/// - Parameter alias: 別名。
	/// - Returns: 密碼位元組。
	/// - Throws: ``GuestSecretStoreError``；別名不存在為 ``GuestSecretStoreError/notFound(alias:)``。
	func secret(for alias: String) async throws -> Data

	/// 刪掉一個別名的密碼。
	/// - Parameter alias: 別名。
	/// - Throws: ``GuestSecretStoreError``；別名不存在為 ``GuestSecretStoreError/notFound(alias:)``。
	func removeSecret(for alias: String) async throws
}
