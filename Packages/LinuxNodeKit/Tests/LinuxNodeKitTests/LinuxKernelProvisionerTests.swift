//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Foundation
import NymphKit
import Testing

// MARK: - LinuxKernelProvisionerTests

private final class LinuxKernelProvisionerTests {

	private func makeArchive() -> LinuxKernelArchive {
		.init(
			version: "test-1",
			archiveURL: URL(string: "https://example.com/kernel.tar.xz")!,
			archiveSHA256: "irrelevant-for-fake",
			innerPath: "vmlinux"
		)
	}

	/// 快取命中 → 直接回快取路徑，不呼叫 fetcher（fetch-on-demand 的「命中不重抓」半段）。
	@Test
	private func `cache hit skips fetcher`() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "linuxnodekittest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let cache: LinuxKernelCache = .init(directory: directory)
		let archive: LinuxKernelArchive = makeArchive()
		let destination: URL = cache.kernelURL(version: archive.version)
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("cached".utf8).write(to: destination)

		let fetcher: FakeKernelArchiveFetcher = .init()
		let provisioner: LinuxKernelProvisioner = .init(cache: cache, fetcher: fetcher)
		let resolved: URL = try await provisioner.prepare(archive)

		#expect(resolved == destination)
		#expect(fetcher.calls.current.isEmpty)
	}

	/// 快取未命中 → 呼叫 fetcher、帶正確 archive / destination（fetch-on-demand 的
	/// 「未命中才抓」半段）。
	@Test
	private func `cache miss invokes fetcher with expected destination`() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "linuxnodekittest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let cache: LinuxKernelCache = .init(directory: directory)
		let archive: LinuxKernelArchive = makeArchive()
		let fetcher: FakeKernelArchiveFetcher = .init()
		let provisioner: LinuxKernelProvisioner = .init(cache: cache, fetcher: fetcher)

		let resolved: URL = try await provisioner.prepare(archive)

		#expect(resolved == cache.kernelURL(version: archive.version))
		#expect(fetcher.calls.current.count == 1)
		#expect(fetcher.calls.current.first?.archive == archive)
		#expect(fetcher.calls.current.first?.destination == cache.kernelURL(version: archive.version))
	}

	/// fetcher 失敗 → 收斂進 `NymphError.internalFailure`（清楚錯誤訊息的落地）、不外洩
	/// 底層錯誤型別。
	@Test
	private func `fetch failure maps to internalFailure`() async throws {
		struct FakeFailure: Error {}
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "linuxnodekittest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let cache: LinuxKernelCache = .init(directory: directory)
		let archive: LinuxKernelArchive = makeArchive()
		let fetcher: FakeKernelArchiveFetcher = .init(failure: FakeFailure())
		let provisioner: LinuxKernelProvisioner = .init(cache: cache, fetcher: fetcher)

		do {
			_ = try await provisioner.prepare(archive)
			Issue.record("expected prepare to throw")
		} catch let error as NymphError {
			guard case .internalFailure = error else {
				Issue.record("expected internalFailure, got \(error)")
				return
			}
		}
	}
}