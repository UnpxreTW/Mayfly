//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// ``GuestSecretStore`` 的失敗面。任何一個 case 都不帶密碼本身。
public enum GuestSecretStoreError: Error, Equatable, Sendable {

	/// 別名不合 ``GuestSecretAlias/isValid(_:)``。
	case invalidAlias(String)

	/// keychain 路徑不是絕對路徑，或含儲存端命令列容不下的字元（`"`、`\`、換行）。
	case invalidKeychainPath(String)

	/// 指定的 keychain 檔不存在。
	case keychainNotFound(path: String)

	/// 密碼本身不能用。
	case invalidSecret(GuestSecretInput.Problem)

	/// 這個別名沒有存過密碼。
	case notFound(alias: String)

	/// keychain 裡這個別名的項目不是這裡寫進去的格式（例如在別處手動建的同名項目）。
	case malformedItem(alias: String)

	/// keychain 鎖著或拒絕授權。帶儲存端的錯誤訊息。
	///
	/// keychain 的解鎖狀態綁在登入工作階段上：ssh 進來的每一條連線都是新的工作階段，在另一條
	/// 連線裡解鎖不算數。要在同一條連線（同一個 shell）裡先解鎖、再接著跑需要密碼的指令。
	case keychainUnavailable(String)

	/// 儲存端指令失敗（``notFound(alias:)`` 與 ``keychainUnavailable(_:)`` 以外的結束碼）。帶結束碼與錯誤訊息。
	case commandFailed(status: Int32, message: String)

	/// 儲存端指令逾時未結束、已被終止——最常見的原因是它在等一個沒有人能點的授權對話框。
	case timedOut(Duration)

	/// 儲存端指令起不來。帶底層錯誤描述。
	case launchFailed(String)
}

// MARK: - + CustomStringConvertible

extension GuestSecretStoreError: CustomStringConvertible {

	/// 人讀訊息。
	public var description: String {
		switch self {
		case let .invalidAlias(alias):
			"invalid secret alias \"\(alias)\" (allowed: letters, digits, '.', '_', '-'; must start with a letter or digit)"
		case let .invalidKeychainPath(path):
			"keychain path \"\(path)\" must be absolute and must not contain a double quote, backslash or line break"
		case let .keychainNotFound(path):
			"keychain file \"\(path)\" does not exist"
		case .invalidSecret(.empty):
			"the password is empty"
		case .invalidSecret(.containsLineBreak):
			"the password contains a line break; sudo -S reads a single line"
		case .invalidSecret(.containsNUL):
			"the password contains a NUL byte"
		case let .notFound(alias):
			"no password stored for \"\(alias)\""
		case let .malformedItem(alias):
			"the keychain item for \"\(alias)\" was not written by mayfly; remove it and set the password again"
		case let .keychainUnavailable(message):
			"the keychain is locked or refused access (\(message)); unlock it in the same session "
				+ "(e.g. `security unlock-keychain` followed by this command in the same shell)"
		case let .commandFailed(status, message):
			"security exited with status \(status): \(message)"
		case let .timedOut(duration):
			"security did not finish within \(duration) (possibly waiting on an authorization dialog; "
				+ "if the item was created by another app, remove it and set the password again)"
		case let .launchFailed(reason):
			"could not launch security: \(reason)"
		}
	}
}
