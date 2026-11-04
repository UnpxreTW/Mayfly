//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 使用者交進來的密碼的整理與驗證。
public enum GuestSecretInput {

	/// 密碼不能用的理由。
	public enum Problem: Error, Equatable, Sendable {

		/// 空值。
		case empty

		/// 含換行：`sudo -S` 只讀一行，換行後的部分永遠送不到。
		case containsLineBreak

		/// 含 NUL：C 字串在這裡就斷了。
		case containsNUL
	}

	/// 從一段原始輸入取出密碼：去掉結尾一個換行（`\n` 或 `\r\n`），其餘位元組原樣保留。
	///
	/// 管線匯入（`printf … |`、從檔案導入）的結尾通常帶一個換行，那不是密碼的一部分；
	/// 只去一個，刻意以空白結尾的密碼不受影響。
	/// - Parameter raw: 原始輸入。
	/// - Returns: 驗過的密碼位元組。
	/// - Throws: ``Problem``。
	public static func parse(_ raw: Data) throws -> Data {
		var bytes: Data = raw
		if bytes.last == 0x0A {
			bytes.removeLast()
			if bytes.last == 0x0D {
				bytes.removeLast()
			}
		}
		try validate(bytes)
		return bytes
	}

	/// 驗一段密碼位元組能不能用。
	/// - Parameter secret: 密碼位元組。
	/// - Throws: ``Problem``。
	public static func validate(_ secret: Data) throws {
		guard !secret.isEmpty else { throw Problem.empty }
		guard
			!secret.contains(0x0A),
			!secret.contains(0x0D)
		else { throw Problem.containsLineBreak }
		guard !secret.contains(0x00) else { throw Problem.containsNUL }
	}
}
