//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation
import Testing

private final class GoldenBundleTests {

	/// 五件套齊 + metadata 可解 → load 鑄出 GoldenBundle。
	@Test
	private func `load succeeds on complete bundle`() throws {
		let root: URL = try makeBundleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "golden.bundle")
		let golden: GoldenBundle = try .load(from: bundle)
		#expect(golden.bundle == bundle)
	}

	/// 缺任一件 → missingComponent、附缺的那個檔。
	@Test
	private func `load throws missing component`() throws {
		let root: URL = try makeBundleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "golden.bundle")
		let hardwareModel: URL = GuestBundleLayout.hardwareModel(in: bundle)
		try FileManager.default.removeItem(at: hardwareModel)
		#expect(throws: GoldenBundleError.missingComponent(hardwareModel)) {
			try GoldenBundle.load(from: bundle)
		}
	}

	/// metadata 存在但毀損 → metadataUndecodable（不鑄造殘缺 bundle）。
	@Test
	private func `load throws undecodable metadata`() throws {
		let root: URL = try makeBundleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "golden.bundle")
		let metadata: URL = GuestBundleLayout.metadata(in: bundle)
		try Data("not-json".utf8).write(to: metadata)
		#expect(throws: GoldenBundleError.metadataUndecodable(metadata)) {
			try GoldenBundle.load(from: bundle)
		}
	}

	// MARK: Private

	/// 造一份佈局完整的最小 bundle fixture、回傳根目錄。
	private func makeBundleFixture() throws -> URL {
		let root: URL = FileManager.default
			.temporaryDirectory
			.appending(component: "GoldenBundleTests-\(UUID().uuidString)")
		let bundle: URL = root.appending(component: "golden.bundle")
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		try Data("disk".utf8).write(to: GuestBundleLayout.diskImage(in: bundle))
		try Data("aux".utf8).write(to: GuestBundleLayout.auxiliaryStorage(in: bundle))
		try Data("machine-identifier".utf8).write(to: GuestBundleLayout.machineIdentifier(in: bundle))
		try Data("hardware-model".utf8).write(to: GuestBundleLayout.hardwareModel(in: bundle))
		let metadata: BundleMetadata = .init(
			macAddress: "0a:1b:2c:3d:4e:5f",
			osBuildVersion: "25F80",
			osVersion: "26.5.1",
			restoreImageSHA256: "deadbeef"
		)
		try JSONEncoder().encode(metadata).write(to: GuestBundleLayout.metadata(in: bundle))
		return root
	}
}
