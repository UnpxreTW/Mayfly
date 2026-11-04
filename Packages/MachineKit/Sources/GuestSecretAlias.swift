//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 密碼別名的字元規則：`[A-Za-z0-9][A-Za-z0-9._-]*`，與 golden／映像別名同一套。
public enum GuestSecretAlias {

	/// 別名是否合規。
	///
	/// 規則收窄的理由不只是好看：別名會原樣放進儲存端的命令列，限定字元集後就不需要任何跳脫。
	/// - Parameter alias: 待驗的別名。
	/// - Returns: 合規為 `true`。
	public static func isValid(_ alias: String) -> Bool {
		guard
			let first: Unicode.Scalar = alias.unicodeScalars.first,
			isASCIIAlphanumeric(first)
		else { return false }
		return alias.unicodeScalars.allSatisfy { scalar in
			isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
		}
	}

	/// 是否為 ASCII 英數字元。
	/// - Parameter scalar: 待判的字元。
	/// - Returns: 是 ASCII 英數字元為 `true`。
	private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
		("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar)
	}
}
