//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 以 macOS keychain 的 generic password 保管 guest 管理者密碼，一律經 `/usr/bin/security` 讀寫。
///
/// 每個別名一個項目：service 固定為 ``service``、account 是別名。預設寫進使用者的 default
/// keychain（通常是 login keychain），也可指定另一個 keychain 檔。
///
/// 為什麼不直接呼叫 Security framework：
///
/// - keychain 項目的存取控制綁在**建立它的程式的簽章**上。`mayfly` 走 ad-hoc 簽章、每次重建
///   簽章都會變，用框架 API 自己寫的項目，換一版 `mayfly` 就可能讀不到、或跳出授權對話框。
///   經 `security` 讀寫，建立者與讀取者始終是同一支系統工具，`mayfly` 重建不影響。
/// - data protection keychain 對沒有 entitlement 的 ad-hoc 簽章程式不可用（見 ``KeychainPreflight``）。
///
/// 值不經命令列參數：寫入時把整行指令從 stdin 交給 `security -i`，`ps` 看不到；讀取時從
/// `security` 的 stdout 收回、不轉印到任何地方。
///
/// 存進 keychain 的資料是密碼位元組的十六進位文字，不是密碼本身：`security … -w` 遇到不可
/// 列印的位元組會改印十六進位，讀回來時分不出是原值還是十六進位——一律存十六進位就沒有這個
/// 歧義，非 ASCII 的密碼也能原樣取回。
public struct KeychainGuestSecretStore: GuestSecretStore {

	// MARK: Public

	/// 項目的 service 名（同時當 label）。
	public static let service: String = "Mayfly guest admin password"

	/// 每次呼叫 `security` 的上限。
	public static let defaultTimeout: Duration = .seconds(30)

	/// - Parameters:
	///   - keychain: keychain 檔路徑；nil＝使用者的 default keychain。
	///   - runner: 跑 `security` 的行程執行器，預設 ``SystemProcessRunner``；測試注入假執行器。
	///   - securityExecutable: `security` 路徑，預設 `/usr/bin/security`。
	///   - timeout: 每次呼叫的上限。
	///   - fileExists: 判斷 keychain 檔在不在，預設查檔案系統；測試注入固定結果。
	public init(
		keychain: String? = nil,
		runner: any ProcessRunner = SystemProcessRunner(),
		securityExecutable: String = "/usr/bin/security",
		timeout: Duration = KeychainGuestSecretStore.defaultTimeout,
		fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
	) {
		self.keychain = keychain
		self.runner = runner
		self.securityExecutable = securityExecutable
		self.timeout = timeout
		self.fileExists = fileExists
	}

	/// 見 ``GuestSecretStore/setSecret(_:for:)``。已存在則覆寫。
	public func setSecret(_ secret: Data, for alias: String) async throws {
		try Self.checkAlias(alias)
		do {
			try GuestSecretInput.validate(secret)
		} catch let problem as GuestSecretInput.Problem {
			throw GuestSecretStoreError.invalidSecret(problem)
		}
		let stored: String = Self.hex(secret)
		let payload: String = Self.hex(Data(stored.utf8))
		let command: String = "add-generic-password -U -a \(alias) -s \"\(Self.service)\" -l \"\(Self.service)\""
			+ " -X \(payload)" + (try keychainSuffix()) + "\n"
		_ = try await run(["-i"], standardInput: Data(command.utf8), alias: alias, redacting: [payload, stored])
	}

	/// 見 ``GuestSecretStore/secret(for:)``。
	public func secret(for alias: String) async throws -> Data {
		try Self.checkAlias(alias)
		let output: Data = try await run(
			["find-generic-password", "-a", alias, "-s", Self.service, "-w"] + (try keychainArguments()),
			standardInput: nil,
			alias: alias,
			redacting: []
		)
		var text: Substring = .init(decoding: output, as: UTF8.self)
		if text.last == "\n" {
			text.removeLast()
		}
		guard
			let secret: Data = Self.decodeHex(text),
			(try? GuestSecretInput.validate(secret)) != nil
		else { throw GuestSecretStoreError.malformedItem(alias: alias) }
		return secret
	}

	/// 見 ``GuestSecretStore/removeSecret(for:)``。
	public func removeSecret(for alias: String) async throws {
		try Self.checkAlias(alias)
		_ = try await run(
			["delete-generic-password", "-a", alias, "-s", Self.service] + (try keychainArguments()),
			standardInput: nil,
			alias: alias,
			redacting: []
		)
	}

	// MARK: Internal

	/// `security` 找不到項目時的結束碼（`errSecItemNotFound`＝-25300 取低 8 位元）。
	internal static let itemNotFoundStatus: Int32 = 44

	/// keychain 鎖著或拒絕授權時的結束碼：`errAuthorizationInteractionNotAllowed`（-60008）與
	/// `errSecInteractionNotAllowed`（-25308）取低 8 位元。前者是實測鎖著的 keychain 讀寫時回的碼。
	///
	/// 結束碼只有 8 位元、不同的 OSStatus 可能撞在同一個值上，所以錯誤裡另帶 `security` 的訊息原文。
	internal static let keychainUnavailableStatuses: Set<Int32> = [152, 36]

	/// 位元組 → 小寫十六進位文字。
	/// - Parameter data: 位元組。
	/// - Returns: 十六進位文字。
	internal static func hex(_ data: Data) -> String {
		data.map { String(format: "%02x", $0) }.joined()
	}

	/// 十六進位文字 → 位元組；長度為奇數或含非十六進位字元時回 nil。
	/// - Parameter text: 十六進位文字。
	/// - Returns: 位元組或 nil。
	internal static func decodeHex(_ text: Substring) -> Data? {
		let scalars: [Unicode.Scalar] = Array(text.unicodeScalars)
		guard scalars.count.isMultiple(of: 2) else { return nil }
		var data: Data = .init(capacity: scalars.count / 2)
		var index: Int = 0
		while index < scalars.count {
			guard
				let high: UInt8 = hexValue(scalars[index]),
				let low: UInt8 = hexValue(scalars[index + 1])
			else { return nil }
			data.append(high << 4 | low)
			index += 2
		}
		return data
	}

	// MARK: Private

	/// keychain 檔路徑；nil＝default keychain。
	private let keychain: String?

	/// 跑 `security` 的行程執行器。
	private let runner: any ProcessRunner

	/// `security` 路徑。
	private let securityExecutable: String

	/// 每次呼叫的上限。
	private let timeout: Duration

	/// 判斷 keychain 檔在不在。
	private let fileExists: @Sendable (String) -> Bool

	/// 別名不合規就擲。
	/// - Parameter alias: 別名。
	/// - Throws: ``GuestSecretStoreError/invalidAlias(_:)``。
	private static func checkAlias(_ alias: String) throws {
		guard GuestSecretAlias.isValid(alias) else { throw GuestSecretStoreError.invalidAlias(alias) }
	}

	/// 一個十六進位字元的值。
	/// - Parameter scalar: 字元。
	/// - Returns: 0–15，非十六進位字元為 nil。
	private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
		switch scalar {
		case "0" ... "9":
			UInt8(scalar.value - 0x30)
		case "a" ... "f":
			UInt8(scalar.value - 0x61 + 10)
		case "A" ... "F":
			UInt8(scalar.value - 0x41 + 10)
		default:
			nil
		}
	}

	/// 指定 keychain 時接在 argv 最後的參數。
	/// - Returns: 空陣列或只含路徑的陣列。
	/// - Throws: ``GuestSecretStoreError/invalidKeychainPath(_:)``。
	private func keychainArguments() throws -> [String] {
		guard let keychain else { return [] }
		try checkKeychainPath(keychain)
		return [keychain]
	}

	/// 指定 keychain 時接在 `security -i` 那行指令最後的一段（含前導空白與引號）。
	/// - Returns: 空字串或 ` "<路徑>"`。
	/// - Throws: ``GuestSecretStoreError/invalidKeychainPath(_:)``。
	private func keychainSuffix() throws -> String {
		guard let keychain else { return "" }
		try checkKeychainPath(keychain)
		return " \"\(keychain)\""
	}

	/// `security -i` 以雙引號收路徑：含雙引號、反斜線或換行的路徑放不進去，直接擋下。相對路徑也擋：
	/// `security` 解析相對路徑的方式與檔案系統不同，這裡查到的檔不一定是它會用的那個。檔案不存在
	/// 也擋：`security add-generic-password` 指向不存在的 keychain 檔時不報錯、改寫進 default keychain。
	/// - Parameter path: keychain 路徑。
	/// - Throws: ``GuestSecretStoreError/invalidKeychainPath(_:)``、``GuestSecretStoreError/keychainNotFound(path:)``。
	private func checkKeychainPath(_ path: String) throws {
		guard
			path.hasPrefix("/"),
			!path.contains(where: { "\"\\\n\r".contains($0) })
		else { throw GuestSecretStoreError.invalidKeychainPath(path) }
		guard fileExists(path) else { throw GuestSecretStoreError.keychainNotFound(path: path) }
	}

	/// 跑一次 `security`，把結束碼映成 ``GuestSecretStoreError``。
	/// - Parameters:
	///   - arguments: 參數。
	///   - standardInput: stdin 內容。
	///   - alias: 別名（錯誤訊息用）。
	///   - redacting: 錯誤訊息裡出現這些文字就遮掉（寫入時的值的兩種編碼）。
	/// - Returns: stdout。
	/// - Throws: ``GuestSecretStoreError``。
	private func run(
		_ arguments: [String],
		standardInput: Data?,
		alias: String,
		redacting: [String]
	) async throws -> Data {
		let result: ProcessRunResult
		do {
			result = try await runner.run(
				executable: securityExecutable,
				arguments: arguments,
				standardInput: standardInput,
				timeout: timeout
			)
		} catch let ProcessRunnerError.timedOut(duration) {
			throw GuestSecretStoreError.timedOut(duration)
		} catch {
			throw GuestSecretStoreError.launchFailed(String(describing: error))
		}
		guard result.exitCode != 0 else { return result.standardOutput }
		var message: String = String(decoding: result.standardError, as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		for secretText in redacting where !secretText.isEmpty {
			message = message.replacingOccurrences(of: secretText, with: "<redacted>")
		}
		switch result.exitCode {
		case Self.itemNotFoundStatus:
			throw GuestSecretStoreError.notFound(alias: alias)
		case let status where Self.keychainUnavailableStatuses.contains(status):
			throw GuestSecretStoreError.keychainUnavailable(message)
		default:
			throw GuestSecretStoreError.commandFailed(status: result.exitCode, message: message)
		}
	}
}
