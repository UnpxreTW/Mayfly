//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import CommonCrypto
import Foundation
import Testing

private final class DslocalUserTests {

	/// triad 形狀 + 獨立重算：entropy 必須等於對外露出的 salt / iterations 重跑
	/// PBKDF2 的結果——驗的是「production 真的算對」，不只是「格式長得對」。
	@Test
	private func `shadow hash data triad matches independent recomputation`() throws {
		let password = "S3cret-\(UUID().uuidString)"
		let inner = try decodePlist(DslocalUser.makeShadowHashData(password: password))
		let triad = try #require(inner["SALTED-SHA512-PBKDF2"] as? [String: Any])
		let entropy = try #require(triad["entropy"] as? Data)
		let salt = try #require(triad["salt"] as? Data)
		let iterations = try #require(triad["iterations"] as? Int)

		#expect(entropy.count == 128)
		#expect(salt.count == 32)
		#expect((30_000 ..< 50_000).contains(iterations), "iterations 應落在 [30000, 50000)")
		#expect(entropy == pbkdf2SHA512(password: password, salt: salt, iterations: iterations))
	}

	/// 同密碼每次呼叫 salt 不同 → 雜湊不同。
	@Test
	private func `shadow hash data is salted per call`() throws {
		let first = try DslocalUser.makeShadowHashData(password: "same-password")
		let second = try DslocalUser.makeShadowHashData(password: "same-password")
		#expect(first != second)
	}

	/// 每個欄位都 array-wrap（dslocal 格式慣例）、且關鍵值正確。
	@Test
	private func `user plist record is array wrapped`() throws {
		let user: DslocalUser = .init(shortName: "runner", uid: 501, realName: "CI Runner")
		let shadowHashData = try DslocalUser.makeShadowHashData(password: "pw")
		let record = try decodePlist(user.userPlist(shadowHashData: shadowHashData))

		let keys = [
			"name", "uid", "gid", "home", "shell", "realname",
			"generateduid", "authentication_authority", "passwd", "ShadowHashData",
			"_writers_hint", "_writers_jpegphoto", "_writers_passwd",
			"_writers_picture", "_writers_realname", "_writers_UserCertificate"
		]
		for key in keys {
			let wrapped = try #require(record[key] as? [Any], "\(key) 應 array-wrap")
			#expect(wrapped.count == 1, "\(key) 應為單元素陣列")
		}

		#expect((record["name"] as? [String])?.first == "runner")
		#expect((record["uid"] as? [String])?.first == "501")
		#expect((record["gid"] as? [String])?.first == "20")
		#expect((record["home"] as? [String])?.first == "/Users/runner")
		#expect((record["shell"] as? [String])?.first == "/bin/zsh")
		#expect((record["_writers_passwd"] as? [String])?.first == "runner")

		let authority = try #require((record["authentication_authority"] as? [String])?.first)
		#expect(authority.hasPrefix(";ShadowHash;"))
		#expect(authority.contains("HASHLIST:<SALTED-SHA512-PBKDF2>"))
		#expect((record["ShadowHashData"] as? [Data])?.first != nil)
	}

	@Test
	private func `admin group edits carry both identifiers`() {
		let generatedUID: UUID = .init()
		let user: DslocalUser = .init(shortName: "admin1", uid: 502, generatedUID: generatedUID, realName: "Admin One")
		let edits = user.adminGroupEdits()
		#expect(edits.appendGroupMembership == "admin1")
		#expect(edits.appendGroupMembers == generatedUID)
	}

	/// 測試端獨立的 PBKDF2-HMAC-SHA512 衍生，dkLen 128，用來交叉驗證 production。
	private func pbkdf2SHA512(password: String, salt: Data, iterations: Int) -> Data {
		var derived: [UInt8] = .init(repeating: 0, count: 128)
		let status = salt.withUnsafeBytes { saltBuffer in
			CCKeyDerivationPBKDF(
				CCPBKDFAlgorithm(kCCPBKDF2),
				password, password.utf8.count,
				saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
				CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
				UInt32(iterations),
				&derived, derived.count
			)
		}
		#expect(status == Int32(kCCSuccess))
		return Data(derived)
	}
}
