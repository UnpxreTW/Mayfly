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

// MARK: - LinuxImageResolverTests

private final class LinuxImageResolverTests {

	/// 內建別名（`alpine`）解到對應 OCI image 參照 ＋ 預設 kernel。
	@Test
	private func `builtin alias resolves to image reference`() throws {
		let resolver: LinuxImageResolver = .init()
		let spec: LinuxGuestSpec = try resolver.resolve("alpine")
		#expect(spec.imageReference == "docker.io/library/alpine:3")
		#expect(spec.kernel == LinuxKernelArchive.default)
	}

	/// 含 `/` 的別名視為完整 OCI 參照、原樣 passthrough。
	@Test
	private func `slash alias passes through as literal reference`() throws {
		let resolver: LinuxImageResolver = .init()
		let spec: LinuxGuestSpec = try resolver.resolve("ghcr.io/example/custom-rootfs")
		#expect(spec.imageReference == "ghcr.io/example/custom-rootfs")
	}

	/// 含 `:` 的別名（如帶 tag 的簡寫參照）同樣 passthrough、不查內建表。
	@Test
	private func `colon alias passes through as literal reference`() throws {
		let resolver: LinuxImageResolver = .init()
		let spec: LinuxGuestSpec = try resolver.resolve("ubuntu:22.04")
		#expect(spec.imageReference == "ubuntu:22.04")
	}

	/// 查無的純別名（無 `/` 無 `:`）→ goldenNotFound。
	@Test
	private func `unknown alias throws goldenNotFound`() {
		let resolver: LinuxImageResolver = .init()
		#expect(throws: NymphError.goldenNotFound("ghost")) {
			try resolver.resolve("ghost")
		}
	}

	/// 自訂別名表可覆寫內建表。
	@Test
	private func `custom alias table overrides builtin`() throws {
		let kernel: LinuxKernelArchive = .init(
			version: "9.9.9",
			archiveURL: URL(string: "https://example.com/kernel.tar.xz")!,
			archiveSHA256: "deadbeef",
			innerPath: "vmlinux"
		)
		let resolver: LinuxImageResolver = .init(aliases: ["custom": "example.com/custom:1"], kernel: kernel)
		let spec: LinuxGuestSpec = try resolver.resolve("custom")
		#expect(spec.imageReference == "example.com/custom:1")
		#expect(spec.kernel == kernel)
		#expect(throws: NymphError.goldenNotFound("alpine")) {
			try resolver.resolve("alpine")
		}
	}
}
