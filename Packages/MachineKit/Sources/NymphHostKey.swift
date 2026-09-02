//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// nymph daemon 的**穩定身份金鑰**：首啟在 state dir 生成、爾後載入同一把——所有
/// ephemeral guest 共用這把公鑰（golden provisioning 把 ``publicKeyLine`` 併進
/// ``ProvisionSpec/authorizedKeys`` 注入 runner 帳號、見 ``MacGuestProvisioner``），nymph
/// 以對應私鑰 SSH 進任一 clone（見 ``MacGuestExec``）。契約決策 #31①。
///
/// 「host key」沿用契約用語：實為 nymph 的**客戶端身份鑰**（穩定、跨 VM 不變），非
/// guest 自身的 SSH host key。私鑰以 state dir 的檔案權限（ssh-keygen 寫 0600）保護；
/// 本型別只持路徑與公鑰行、不把私鑰材料讀進記憶體。
public struct NymphHostKey: Sendable {

	// MARK: Public

	/// 私鑰檔位置（`ssh -i` 用）。
	public let privateKeyURL: URL

	/// 公鑰單行內容——即 authorized_keys 條目（`ssh-ed25519 AAAA… comment`）。呼叫端
	/// 把它併進 ``ProvisionSpec/authorizedKeys`` 完成注入。
	public let publicKeyLine: String

	/// load-or-generate：`stateDirectory/keyName`（+ `.pub`）已存在就載入、否則生成一
	/// 把。**idempotent**——daemon 首啟生成、爾後載入同一把（穩定身份的關鍵）。缺目錄
	/// 先建立。
	///
	/// - Parameters:
	///   - stateDirectory: nymph state dir（私鑰落點；權限由呼叫端 / ssh-keygen 保證）。
	///   - keyName: 私鑰檔名，預設 `nymph_ed25519`；公鑰為同名 + `.pub`。
	///   - comment: 生成時寫進公鑰的註解，預設 `mayfly-nymph`。
	///   - generator: 金鑰產生器，預設 ``SystemNymphKeyGenerator``（真 ssh-keygen）。
	public static func loadOrGenerate(
		in stateDirectory: URL,
		keyName: String = "nymph_ed25519",
		comment: String = "mayfly-nymph",
		generator: any NymphKeyGenerator = SystemNymphKeyGenerator()
	) async throws -> NymphHostKey {
		let privateKeyURL: URL = stateDirectory.appending(component: keyName)
		let publicKeyURL: URL = stateDirectory.appending(component: keyName + ".pub")
		let manager: FileManager = .default
		let present: Bool = manager.fileExists(atPath: privateKeyURL.path)
			&& manager.fileExists(atPath: publicKeyURL.path)
		if !present {
			try manager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
			try await generator.generate(privateKeyURL: privateKeyURL, comment: comment)
		}
		return try load(privateKeyURL: privateKeyURL, publicKeyURL: publicKeyURL)
	}

	/// 從已存在的私鑰 / 公鑰檔鑄造。公鑰讀不到 → ``NymphHostKeyError/publicKeyUnreadable(_:)``；
	/// 內容空 → ``NymphHostKeyError/publicKeyEmpty(_:)``。公鑰行去首尾空白 / 換行。
	public static func load(privateKeyURL: URL, publicKeyURL: URL) throws -> NymphHostKey {
		guard let raw = try? String(contentsOf: publicKeyURL, encoding: .utf8) else {
			throw NymphHostKeyError.publicKeyUnreadable(publicKeyURL)
		}
		let line: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !line.isEmpty else {
			throw NymphHostKeyError.publicKeyEmpty(publicKeyURL)
		}
		return NymphHostKey(privateKeyURL: privateKeyURL, publicKeyLine: line)
	}

	/// - Parameters:
	///   - privateKeyURL: 私鑰檔位置。
	///   - publicKeyLine: 公鑰單行（authorized_keys 條目）。
	public init(privateKeyURL: URL, publicKeyLine: String) {
		self.privateKeyURL = privateKeyURL
		self.publicKeyLine = publicKeyLine
	}
}
