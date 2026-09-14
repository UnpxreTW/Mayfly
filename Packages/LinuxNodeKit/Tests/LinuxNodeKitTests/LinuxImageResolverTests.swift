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
		let resolver: LinuxImageResolver = .init(builtInAliases: ["custom": "example.com/custom:1"], kernel: kernel)
		let spec: LinuxGuestSpec = try resolver.resolve("custom")
		#expect(spec.imageReference == "example.com/custom:1")
		#expect(spec.kernel == kernel)
		#expect(throws: NymphError.goldenNotFound("alpine")) {
			try resolver.resolve("alpine")
		}
	}

	/// 別名表的條目解得到，且 `rootfsGiB` 換算成 bytes 帶進 spec。
	@Test
	private func `manifest alias resolves with its rootfs size`() throws {
		let manifest: LinuxImageManifest = .init(
			version: 1,
			images: ["ci-lint": .init(reference: "ghcr.io/example/ci-lint@sha256:abc", rootfsGiB: 4)]
		)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let spec: LinuxGuestSpec = try resolver.resolve("ci-lint")
		#expect(spec.imageReference == "ghcr.io/example/ci-lint@sha256:abc")
		// 4 GiB＝4 × 1024³，值寫死、不由被測程式推導。
		#expect(spec.rootfsSizeInBytes == 4_294_967_296)
	}

	/// 別名表沒寫 `rootfsGiB` 的條目不帶大小，交給引擎用自己的預設。
	@Test
	private func `manifest alias without rootfs size leaves it unset`() throws {
		let manifest: LinuxImageManifest = .init(
			version: 1,
			images: ["ci-swift": .init(reference: "ghcr.io/example/ci-swift:1")]
		)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let spec: LinuxGuestSpec = try resolver.resolve("ci-swift")
		#expect(spec.rootfsSizeInBytes == nil)
	}

	/// 別名表與內建表同名時以別名表為準（操作者手上那份檔才是這台機器當下的答案）。
	@Test
	private func `manifest alias overrides builtin of the same name`() throws {
		let manifest: LinuxImageManifest = .init(
			version: 1,
			images: ["alpine": .init(reference: "ghcr.io/example/alpine-pinned@sha256:abc")]
		)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let spec: LinuxGuestSpec = try resolver.resolve("alpine")
		#expect(spec.imageReference == "ghcr.io/example/alpine-pinned@sha256:abc")
	}

	/// 像 OCI 參照的字串仍先 passthrough——別名表不會把它接走。
	@Test
	private func `passthrough still wins over the manifest`() throws {
		let manifest: LinuxImageManifest = .init(
			version: 1,
			images: ["alpine": .init(reference: "ghcr.io/example/alpine-pinned@sha256:abc")]
		)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let spec: LinuxGuestSpec = try resolver.resolve("docker.io/library/alpine:3")
		#expect(spec.imageReference == "docker.io/library/alpine:3")
	}

	/// 別名表在、但查無此別名時仍落回內建表。
	@Test
	private func `builtin still resolves when the manifest has no such alias`() throws {
		let manifest: LinuxImageManifest = .init(
			version: 1,
			images: ["ci-lint": .init(reference: "ghcr.io/example/ci-lint@sha256:abc")]
		)
		let resolver: LinuxImageResolver = .init(manifest: manifest)
		let spec: LinuxGuestSpec = try resolver.resolve("alpine")
		#expect(spec.imageReference == "docker.io/library/alpine:3")
	}
}
