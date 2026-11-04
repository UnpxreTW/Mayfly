//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Containerization
import ContainerizationOCI
import Foundation
import Testing

// MARK: - SingleLayerImageLayoutTests

/// 寫出來的 layout 一律交給上游真正的 `ImageStore.load(from:)` 驗——自己讀回自己寫的 JSON
/// 證明不了載入端收不收。
private final class SingleLayerImageLayoutTests {

	/// 載入後能以參照取回，config 只剩這一層、執行參數照 base 複製。
	@Test
	private func `layout loads into an image store with a single layer`() async throws {
		let sandbox: Sandbox = try .init()
		defer { sandbox.remove() }
		let layer: URL = try sandbox.layer(Data("rootfs-bytes".utf8))
		let reference: String = try SingleLayerImageLayout.reference(alias: "linux-6.3.3", tag: "t1")
		let output: SingleLayerImageLayout.Output = try SingleLayerImageLayout.write(
			layer: layer,
			baseConfig: Sandbox.baseConfig,
			reference: reference,
			createdBy: "bake",
			baseReference: "registry.example/base:1",
			baseDigest: "sha256:0123",
			created: Date(timeIntervalSince1970: 0),
			into: sandbox.layout
		)

		let store: ImageStore = try .init(path: sandbox.store)
		let loaded: [Containerization.Image] = try await store.load(from: sandbox.layout)
		#expect(loaded.map(\.reference) == [reference])
		let image: Containerization.Image = try await store.get(reference: reference)
		let config: ContainerizationOCI.Image = try await image.config(for: .current)
		#expect(config.rootfs.diffIDs == [output.layerDigest])
		#expect(config.history?.count == 1)
		#expect(config.history?.first?.createdBy == "bake")
		#expect(config.config?.env == Sandbox.baseConfig.config?.env)
		#expect(config.config?.workingDir == "/root")
		let manifest: Manifest = try await image.manifest(for: .current)
		#expect(manifest.layers.map(\.mediaType) == [MediaTypes.imageLayer])
		#expect(manifest.layers.map(\.digest) == [output.layerDigest])
		#expect(manifest.annotations?["org.opencontainers.image.base.name"] == "registry.example/base:1")
		#expect(manifest.annotations?["org.opencontainers.image.base.digest"] == "sha256:0123")
		#expect(output.layerSize == Int64("rootfs-bytes".utf8.count))
		#expect(!FileManager.default.fileExists(atPath: layer.path))
	}

	/// 載入的映像能再以 `save` 匯出——`save` 只收 index 形的映像，順帶驗了形狀。
	@Test
	private func `loaded image can be saved back to a layout`() async throws {
		let sandbox: Sandbox = try .init()
		defer { sandbox.remove() }
		let reference: String = try SingleLayerImageLayout.reference(alias: "ci", tag: "t1")
		_ = try SingleLayerImageLayout.write(
			layer: sandbox.layer(Data("x".utf8)),
			baseConfig: Sandbox.baseConfig,
			reference: reference,
			createdBy: "bake",
			baseReference: "registry.example/base:1",
			baseDigest: nil,
			created: Date(timeIntervalSince1970: 0),
			into: sandbox.layout
		)
		let store: ImageStore = try .init(path: sandbox.store)
		_ = try await store.load(from: sandbox.layout)
		let out: URL = sandbox.root.appending(component: "saved")
		try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
		try await store.save(references: [reference], out: out)
		#expect(FileManager.default.fileExists(atPath: out.appending(component: "index.json").path))
	}

	/// 非空目錄不寫——layout 不與既有內容混堆。
	@Test
	private func `non empty directory is rejected`() throws {
		let sandbox: Sandbox = try .init()
		defer { sandbox.remove() }
		try FileManager.default.createDirectory(at: sandbox.layout, withIntermediateDirectories: true)
		try Data("stale".utf8).write(to: sandbox.layout.appending(component: "stale"))
		let layer: URL = try sandbox.layer(Data("x".utf8))
		#expect(throws: SingleLayerImageLayout.LayoutError.directoryNotEmpty(path: sandbox.layout.path)) {
			try SingleLayerImageLayout.write(
				layer: layer,
				baseConfig: Sandbox.baseConfig,
				reference: "mayfly.local/ci:t1",
				createdBy: "bake",
				baseReference: "registry.example/base:1",
				baseDigest: nil,
				created: Date(timeIntervalSince1970: 0),
				into: sandbox.layout
			)
		}
		#expect(FileManager.default.fileExists(atPath: layer.path))
	}

	/// 參照：別名轉小寫、掛在本機網域下。
	@Test
	private func `reference lowercases the alias under the local domain`() throws {
		let reference: String = try SingleLayerImageLayout.reference(alias: "Linux-6.3.3", tag: "20261104-120000")
		#expect(reference == "mayfly.local/linux-6.3.3:20261104-120000")
	}

	/// 組不出合法參照的別名或標籤在這裡就擋下。
	@Test(arguments: [("ci-", "t1"), ("team/ci", "t1"), ("ci", "a/b"), ("", "t1"), ("ci", "")])
	private func `invalid alias or tag is rejected`(alias: String, tag: String) {
		#expect(throws: SingleLayerImageLayout.LayoutError.self) {
			try SingleLayerImageLayout.reference(alias: alias, tag: tag)
		}
	}
}

// MARK: - Sandbox

/// 每個測試一個暫存根目錄：層檔、layout、image store 各放一處。
private struct Sandbox {

	/// 建一個新的暫存根目錄。
	internal init() throws {
		self.root = FileManager.default.temporaryDirectory.appending(component: "mayfly-layout-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	/// base 映像的 config：兩層、兩條歷史，用來驗寫出的 config 只剩一層。
	internal static let baseConfig: ContainerizationOCI.Image = .init(
		architecture: "arm64",
		os: "linux",
		config: .init(env: ["PATH=/usr/bin:/bin", "LANG=C.UTF-8"], cmd: ["/bin/bash"], workingDir: "/root"),
		rootfs: .init(type: "layers", diffIDs: ["sha256:aaaa", "sha256:bbbb"]),
		history: [.init(createdBy: "first"), .init(createdBy: "second")]
	)

	/// layout 目錄（尚未建立）。
	internal var layout: URL { root.appending(component: "layout") }

	/// image store 目錄。
	internal var store: URL { root.appending(component: "store") }

	/// 暫存根目錄。
	internal let root: URL

	/// 落一份層檔。
	/// - Parameter data: 層的內容。
	/// - Returns: 層檔路徑。
	internal func layer(_ data: Data) throws -> URL {
		let url: URL = root.appending(component: "layer-\(UUID().uuidString).tar")
		try data.write(to: url)
		return url
	}

	/// 清掉整個暫存根目錄。
	internal func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}
