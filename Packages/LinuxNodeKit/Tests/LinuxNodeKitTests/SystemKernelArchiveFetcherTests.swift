//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Foundation
import Testing

// MARK: - SystemKernelArchiveFetcherTests

private final class SystemKernelArchiveFetcherTests {

	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "linuxnodekittest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	/// 鏡射 kata 封存佈局：`vmlinux.container` 是指向同目錄版本化真檔 `vmlinux-<ver>` 的相對
	/// symlink。安裝進快取後，快取產物必須是**跟隨過 symlink 的真 regular file**、不是懸空
	/// symlink——`copyItem` 保留 symlink，直接複製連結會在解壓工作目錄清掉後於快取留下懸空
	/// 連結（`isCached` 跟隨懸空連結恆 false → 每次重抓、永遠壞）。此測試在修前紅、修後綠。
	@Test
	private func `install resolves kata symlink into a real cached kernel`() throws {
		try withTemporaryDirectory { root in
			// 造 extractDir，鏡射 kata `opt/kata/share/kata-containers` 佈局
			let version: String = "6.12.28-153"
			let realBytes: Data = Data("REAL-KERNEL-BYTES-\(version)".utf8)
			let layoutDirectory: URL = root
				.appending(component: "extracted")
				.appending(component: "opt")
				.appending(component: "kata")
				.appending(component: "share")
				.appending(component: "kata-containers")
			try FileManager.default.createDirectory(at: layoutDirectory, withIntermediateDirectories: true)

			let realKernel: URL = layoutDirectory.appending(component: "vmlinux-\(version)")
			try realBytes.write(to: realKernel)
			let linkKernel: URL = layoutDirectory.appending(component: "vmlinux.container")
			try FileManager.default.createSymbolicLink(atPath: linkKernel.path, withDestinationPath: "vmlinux-\(version)")

			// 快取落點
			let cacheRoot: URL = root.appending(component: "cache")
			let cache: LinuxKernelCache = .init(directory: cacheRoot)
			let destination: URL = cache.kernelURL(version: version)

			// 真跑 fetcher 的安裝路徑（symlink 解析 + staging → rename），不連網
			try SystemKernelArchiveFetcher().install(extractedKernel: linkKernel, to: destination)

			// 模擬 fetcher `defer { removeItem(workDirectory) }`：真檔隨解壓工作目錄消失
			try FileManager.default.removeItem(at: root.appending(component: "extracted"))

			// ① 快取產物是真 regular file，非 symlink、非懸空
			#expect(FileManager.default.fileExists(atPath: destination.path))
			let type: FileAttributeType? = try FileManager.default
				.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
			#expect(type == .typeRegular)
			#expect(type != .typeSymbolicLink)
			#expect(FileManager.default.contents(atPath: destination.path) == realBytes)

			// ② isCached 回 true（存在即完整的快取契約，不再每次重抓）
			#expect(cache.isCached(version: version))
		}
	}
}
