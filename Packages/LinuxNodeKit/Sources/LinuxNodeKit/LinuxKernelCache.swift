//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// kernel 二進位的本機快取：目錄管理、以版本命名、串流 sha256。純 Foundation +
/// CryptoKit，無 arch gate——快取邏輯本身跟 VM 框架無關，可獨立單測（比照 MachineKit
/// 的 `RestoreImageCache` 同一設計理由）。
public struct LinuxKernelCache: Sendable {

	// MARK: Public

	/// 快取目錄；預設 `<nymph state dir>/kernels`（``LinuxNodePaths/kernelCacheDirectory(environment:)``）。
	public let directory: URL

	public init(directory: URL = LinuxNodePaths.kernelCacheDirectory()) {
		self.directory = directory
	}

	/// 依版本推導的本機 kernel 落點（`<directory>/<version>/vmlinux-arm64`）。
	public func kernelURL(version: String) -> URL {
		directory.appending(component: version).appending(component: "vmlinux-arm64")
	}

	/// 對應版本的 kernel 是否已在快取。**存在即視為完整**——下載完整性靠 fetcher
	/// 「temp 落地後才 rename 成最終名」保證（半成品不會以最終名存在，同
	/// `RestoreImageCache` 的契約）。
	public func isCached(version: String) -> Bool {
		FileManager.default.fileExists(atPath: kernelURL(version: version).path)
	}

	/// 串流計算檔案 sha256（8 MiB chunk），回小寫 hex。不依賴 instance state，設計成
	/// static 供 ``SystemKernelArchiveFetcher`` 共用同一份實作（單一正本）。
	public static func sha256(of url: URL) throws -> String {
		let handle: FileHandle = try .init(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher: SHA256 = .init()
		while let chunk = try handle.read(upToCount: LinuxKernelCache.chunkSize), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	// MARK: Private

	/// sha256 串流 chunk 大小。
	private static let chunkSize: Int = 8 * 1024 * 1024
}
