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

// MARK: - LinuxKernelCacheTests

private final class LinuxKernelCacheTests {

	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "linuxnodekittest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	/// `kernelURL` 依版本推導 `<directory>/<version>/vmlinux-arm64`。
	@Test
	private func `kernel url derives from version`() {
		let cache: LinuxKernelCache = .init(directory: URL(fileURLWithPath: "/tmp/kernels"))
		let url: URL = cache.kernelURL(version: "3.17.0")
		#expect(url.path == "/tmp/kernels/3.17.0/vmlinux-arm64")
	}

	/// 檔案不存在 → isCached 為 false；寫入後 → true（存在即視為完整的快取契約）。
	@Test
	private func `isCached reflects file presence`() throws {
		try withTemporaryDirectory { directory in
			let cache: LinuxKernelCache = .init(directory: directory)
			#expect(!cache.isCached(version: "3.17.0"))
			let url: URL = cache.kernelURL(version: "3.17.0")
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data("placeholder".utf8).write(to: url)
			#expect(cache.isCached(version: "3.17.0"))
		}
	}

	/// sha256 對已知內容算出已知雜湊——驗串流實作正確，不只是「不崩潰」。
	@Test
	private func `sha256 matches known digest`() throws {
		try withTemporaryDirectory { directory in
			let fileURL: URL = directory.appending(component: "sample.txt")
			try Data("hello mayfly\n".utf8).write(to: fileURL)
			let digest: String = try LinuxKernelCache.sha256(of: fileURL)
			#expect(digest == "28fd0da9fc1a0d7a9f9428a0bd97fadf91ac2bc4f820cbd812360ee4d3dc8111")
		}
	}
}