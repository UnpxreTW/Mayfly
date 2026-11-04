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

#if canImport(Darwin)
import Darwin
#endif

/// `secret set` 取得密碼的兩條路：終端機上無回顯輸入兩次，或從 stdin 一次讀完。
internal enum SecretPrompt {

	/// 取得密碼。
	///
	/// stdin 是終端機時從終端機讀（不回顯、輸入兩次比對）；否則讀 stdin 到結束、去掉結尾一個換行。
	/// - Parameter alias: 別名（只用於提示文字）。
	/// - Returns: 驗過的密碼位元組。
	/// - Throws: ``GuestSecretInput/Problem``；兩次輸入不同或終端機讀取失敗為 `ValidationError`。
	internal static func read(alias: String) throws -> Data {
		guard isatty(STDIN_FILENO) != 0 else {
			return try GuestSecretInput.parse(FileHandle.standardInput.readDataToEndOfFile())
		}
		let first: Data = try readHidden(prompt: "Password for \(alias): ")
		let second: Data = try readHidden(prompt: "Retype password for \(alias): ")
		guard first == second else { throw ValidationError("the two passwords do not match.") }
		try GuestSecretInput.validate(first)
		return first
	}

	/// 終端機輸入上限（含結尾 NUL）。
	private static let bufferSize: Int = 4096

	/// 從終端機讀一行、不回顯。
	/// - Parameter prompt: 提示文字（寫到終端機、不經 stdout）。
	/// - Returns: 讀到的位元組（不含換行）。
	/// - Throws: 讀取失敗或輸入過長時為 `ValidationError`。
	private static func readHidden(prompt: String) throws -> Data {
		var buffer: [CChar] = .init(repeating: 0, count: bufferSize)
		defer {
			// 盡力清掉緩衝裡的明文；Swift 不保證沒有其他副本，這裡只收自己手上這一份。
			for index in buffer.indices {
				buffer[index] = 0
			}
		}
		guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
			throw ValidationError("could not read the password from the terminal.")
		}
		let length: Int = buffer.firstIndex(of: 0) ?? buffer.count
		guard length < bufferSize - 1 else { throw ValidationError("the password is longer than \(bufferSize - 2) bytes.") }
		return Data(buffer.prefix(length).map { UInt8(bitPattern: $0) })
	}
}
