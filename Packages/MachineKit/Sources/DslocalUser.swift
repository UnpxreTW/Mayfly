//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import CommonCrypto
import Foundation
import Security

/// 離線建立 macOS 本機（dslocal）admin 使用者紀錄。
///
/// 對應 `/private/var/db/dslocal/nodes/Default/users/<name>.plist`。把
/// pycreateuserpkg（Apache-2.0）的 SALTED-SHA512-PBKDF2 密碼雜湊邏輯 clean-room
/// 重寫成 Swift——不抄原始碼、只實作同一套格式。產出純 plist bytes、不碰任何檔案
/// 系統，可純紙上單測。
///
/// 安裝後的 guest 停在 Setup Assistant、無任何帳號；macOS 14+ 的「不重跑 Setup
/// Assistant」保護只在「已存在本機使用者」時生效，所以離線寫入這筆紀錄（搭配
/// ``SetupAssistantSkip`` 的標記）才是真正跳過建立帳號流程的機制。
public struct DslocalUser: Sendable {

	// MARK: Public

	/// 產生 `ShadowHashData` 的內層 binary plist：`{SALTED-SHA512-PBKDF2:
	/// {entropy, salt, iterations}}`。salt（32 bytes）與 iterations（落在
	/// `[30000, 50000)`）每次隨機，讓相同密碼也產不同雜湊。
	///
	/// 回傳的是「內層」plist bytes；``userPlist(shadowHashData:)`` 會把它以
	/// array-wrap 放進 `ShadowHashData` 欄位。
	public static func makeShadowHashData(password: String) throws -> Data {
		let salt = try randomBytes(count: saltByteCount)
		let iterations = try randomIterations()
		let entropy = try deriveKey(password: password, salt: salt, iterations: iterations)
		let triad: [String: Any] = [
			"entropy": entropy,
			"salt": salt,
			"iterations": iterations
		]
		let inner: [String: Any] = [shadowHashKey: triad]
		return try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
	}

	public var shortName: String
	public var uid: Int
	public var primaryGID: Int
	public var generatedUID: UUID
	public var realName: String
	public var shell: String

	/// 組出整筆 dslocal 使用者紀錄的 binary plist。每個值都 array-wrap——dslocal
	/// 紀錄的格式慣例是「即使單值也包成單元素陣列」。`shadowHashData` 先由
	/// ``makeShadowHashData(password:)`` 產生再傳入。
	///
	/// `_writers_*` 六欄是 DirectoryService 的 self-write ACL（與 pycreateuserpkg
	/// 對齊）：授權該使用者改自己的 passwd / realname / hint / 照片等欄位、值皆為
	/// 自己的 shortName。缺了它們 SSH 登入仍可，但使用者改自己密碼會行為異常。
	public func userPlist(shadowHashData: Data) throws -> Data {
		let record: [String: Any] = [
			"name": [shortName],
			"uid": [String(uid)],
			"gid": [String(primaryGID)],
			"home": ["/Users/\(shortName)"],
			"shell": [shell],
			"realname": [realName],
			"generateduid": [generatedUID.uuidString],
			"authentication_authority": [";ShadowHash;HASHLIST:<\(Self.shadowHashKey)>"],
			"passwd": ["********"],
			"ShadowHashData": [shadowHashData],
			"_writers_hint": [shortName],
			"_writers_jpegphoto": [shortName],
			"_writers_passwd": [shortName],
			"_writers_picture": [shortName],
			"_writers_realname": [shortName],
			"_writers_UserCertificate": [shortName]
		]
		return try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
	}

	/// admin 群組（`admin.plist`）需要的兩處追加：`GroupMembership` 收 shortName、
	/// `GroupMembers` 收 generatedUID。兩者都要寫、缺一 admin 判定不一致。
	public func adminGroupEdits() -> (appendGroupMembership: String, appendGroupMembers: UUID) {
		(appendGroupMembership: shortName, appendGroupMembers: generatedUID)
	}

	public init(
		shortName: String,
		uid: Int,
		primaryGID: Int = 20,
		generatedUID: UUID = UUID(),
		realName: String,
		shell: String = "/bin/zsh"
	) {
		self.shortName = shortName
		self.uid = uid
		self.primaryGID = primaryGID
		self.generatedUID = generatedUID
		self.realName = realName
		self.shell = shell
	}

	// MARK: Private

	/// dslocal ShadowHashData 採用的雜湊方案 key。
	private static let shadowHashKey = "SALTED-SHA512-PBKDF2"

	/// salt 長度（bytes）。
	private static let saltByteCount = 32

	/// 衍生金鑰長度（bytes）。
	private static let derivedKeyByteCount = 128

	/// 密碼學亂數 bytes。
	private static func randomBytes(count: Int) throws -> Data {
		var bytes: [UInt8] = .init(repeating: 0, count: count)
		let status: Int32 = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
		guard status == errSecSuccess else {
			throw DslocalUserError.randomGenerationFailed(status: status)
		}
		return Data(bytes)
	}

	/// 隨機 iteration 次數，落在 `[30000, 50000)`。
	private static func randomIterations() throws -> Int {
		let raw = try randomBytes(count: 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
		return 30_000 + Int(raw % 20_000)
	}

	/// PBKDF2-HMAC-SHA512 衍生。
	private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
		var derived: [UInt8] = .init(repeating: 0, count: derivedKeyByteCount)
		// CCKeyDerivationPBKDF 回 Int32：顯式標註避免 formatter 的 propertyTypes
		// 規則對大寫開頭呼叫誤判型別、改寫成編譯不過的程式碼。
		let status: Int32 = salt.withUnsafeBytes { saltBuffer in
			CCKeyDerivationPBKDF(
				CCPBKDFAlgorithm(kCCPBKDF2),
				password, password.utf8.count,
				saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
				CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
				UInt32(iterations),
				&derived, derived.count
			)
		}
		guard status == Int32(kCCSuccess) else {
			throw DslocalUserError.keyDerivationFailed(status: status)
		}
		return Data(derived)
	}
}
