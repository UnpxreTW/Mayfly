//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// kernel 的 fetch-on-demand 編排：快取命中直接回路徑，否則抓＋驗＋落地——發佈物 / repo
/// 永不 bundle kernel、一律執行期 fetch＋sha256 pin，失敗給清楚錯誤訊息。arch-neutral、
/// 可用假 ``KernelArchiveFetching`` 單測（不必真連網），真機接線見 ``LinuxGuestEngine``。
public struct LinuxKernelProvisioner: Sendable {

	// MARK: Public

	public let cache: LinuxKernelCache

	public init(
		cache: LinuxKernelCache = .init(),
		fetcher: any KernelArchiveFetching = SystemKernelArchiveFetcher()
	) {
		self.cache = cache
		self.fetcher = fetcher
	}

	/// 備妥 `archive` 指定的 kernel、回本機路徑。快取命中即回、不重抓。
	///
	/// - Throws: 抓取 / 解壓 / sha256 驗證失敗一律收斂進
	///   ``NymphError/internalFailure(_:)``（帶底層描述——「清楚錯誤訊息」的落地）。
	public func prepare(_ archive: LinuxKernelArchive = .default) async throws -> URL {
		let destination: URL = cache.kernelURL(version: archive.version)
		guard !cache.isCached(version: archive.version) else {
			return destination
		}
		do {
			try await fetcher.fetch(archive, to: destination)
		} catch {
			throw NymphError.internalFailure("linux kernel fetch failed (\(archive.version)): \(error)")
		}
		return destination
	}

	// MARK: Private

	private let fetcher: any KernelArchiveFetching
}