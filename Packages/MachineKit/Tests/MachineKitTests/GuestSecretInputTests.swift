//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation
import Testing

// MARK: - GuestSecretInputTests

private final class GuestSecretInputTests {

	/// 結尾一個 `\n` 或 `\r\n` 去掉，其餘原樣（含結尾空白）。
	@Test(arguments: [
		("fake-secret\n", "fake-secret"),
		("fake-secret\r\n", "fake-secret"),
		("fake-secret", "fake-secret"),
		("fake secret \n", "fake secret "),
		("假的密碼\n", "假的密碼")
	])
	private func `parse strips one trailing line break`(raw: String, expected: String) throws {
		#expect(try GuestSecretInput.parse(Data(raw.utf8)) == Data(expected.utf8))
	}

	/// 去掉結尾換行後還有換行、是空值或含 NUL → 拒收。
	@Test(arguments: [
		("", GuestSecretInput.Problem.empty),
		("\n", .empty),
		("\n\n", .containsLineBreak),
		("fake\nsecret", .containsLineBreak),
		("fake\rsecret", .containsLineBreak),
		("fake\0secret", .containsNUL)
	])
	private func `parse rejects unusable input`(raw: String, problem: GuestSecretInput.Problem) {
		#expect(throws: problem) {
			try GuestSecretInput.parse(Data(raw.utf8))
		}
	}

	/// 別名字元規則：英數開頭，其後英數與 `.`、`_`、`-`。
	@Test(arguments: [
		("golden-xcode", true),
		("Golden_1.2", true),
		("9a", true),
		("", false),
		("-golden", false),
		(".golden", false),
		("golden xcode", false),
		("golden\"x", false),
		("golden/x", false),
		("金色", false)
	])
	private func `alias rule`(alias: String, valid: Bool) {
		#expect(GuestSecretAlias.isValid(alias) == valid)
	}
}
