//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// `.ipsw` restore image 的本機快取：目錄管理、以 build version 命名、串流 SHA256。
///
/// ~16.5GB 的 .ipsw 重抓代價高，命中就跳過下載。SHA256 為**稽核**用途（寫進
/// bundle 的 `metadata.json`、供日後偵測來源變動），不是 cache 完整性閘門——
/// 下載完整性靠 provider 的「temp 落地後再 atomic rename 成最終名」保證（半成品
/// 永遠不會以最終名存在）。純 Foundation、無 arch gate、可獨立單測。
public struct RestoreImageCache: Sendable {

	/// 快取目錄；預設 `~/Library/Caches/Mayfly`。
	public let directory: URL

	/// 依 build version 推導的本機 .ipsw 位置（`<buildVersion>.ipsw`）。
	/// `buildVersion` 來自 `VZMacOSRestoreImage`（Apple 簽署目錄、格式如 `23A344`）、
	/// 視為可信、不另做路徑分隔字元淨化。
	public func imageURL(buildVersion: String) -> URL {
		directory.appending(component: "\(buildVersion).ipsw")
	}

	/// 對應 build 的 .ipsw 是否已在快取。**存在即視為完整且正確**——前提是
	/// 快取目錄為本程式碼獨佔（provider 以同卷 atomic rename 保證最終名只在下載
	/// 完整時出現）；外部手動丟進的檔不在保證內。
	public func isCached(buildVersion: String) -> Bool {
		FileManager.default.fileExists(atPath: imageURL(buildVersion: buildVersion).path)
	}

	/// 串流計算檔案 SHA256（8 MiB chunk、記憶體上限固定），回傳小寫 hex。
	public func sha256(of url: URL) throws -> String {
		let handle: FileHandle = try .init(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher: SHA256 = .init()
		while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	public init(directory: URL? = nil) {
		if let directory {
			self.directory = directory
		} else {
			let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			self.directory = caches.appending(component: "Mayfly")
		}
	}

	/// SHA256 串流 chunk 大小。
	private let chunkSize = 8 * 1024 * 1024
}
