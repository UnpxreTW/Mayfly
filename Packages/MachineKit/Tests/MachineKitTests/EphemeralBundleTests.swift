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

private final class EphemeralBundleTests {

	/// 五件套齊 + metadata 標 ephemeral → load 鑄出 EphemeralBundle。
	@Test
	private func `load succeeds on ephemeral bundle`() throws {
		let root: URL = try makeBundleFixture(ephemeral: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "job.bundle")
		let clone: EphemeralBundle = try .load(from: bundle)
		#expect(clone.bundle == bundle)
	}

	/// 沒有 ephemeral 標記（golden / 外來 bundle）→ notEphemeral——跨行程也包不成
	/// 可銷毀複本、destroy 刪不到 golden 的性質保留。
	@Test
	private func `load rejects bundle without ephemeral mark`() throws {
		let root: URL = try makeBundleFixture(ephemeral: nil)
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "job.bundle")
		#expect(throws: EphemeralBundleError.notEphemeral(bundle)) {
			try EphemeralBundle.load(from: bundle)
		}
	}

	/// 缺任一件 → missingComponent、附缺的那個檔。
	@Test
	private func `load throws missing component`() throws {
		let root: URL = try makeBundleFixture(ephemeral: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "job.bundle")
		let diskImage: URL = GuestBundleLayout.diskImage(in: bundle)
		try FileManager.default.removeItem(at: diskImage)
		#expect(throws: EphemeralBundleError.missingComponent(diskImage)) {
			try EphemeralBundle.load(from: bundle)
		}
	}

	/// metadata 毀損 → metadataUndecodable。
	@Test
	private func `load throws undecodable metadata`() throws {
		let root: URL = try makeBundleFixture(ephemeral: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let bundle: URL = root.appending(component: "job.bundle")
		let metadata: URL = GuestBundleLayout.metadata(in: bundle)
		try Data("not-json".utf8).write(to: metadata)
		#expect(throws: EphemeralBundleError.metadataUndecodable(metadata)) {
			try EphemeralBundle.load(from: bundle)
		}
	}

	// MARK: Private

	/// 造一份佈局完整的最小 bundle fixture（可控 ephemeral 標記）、回傳根目錄。
	private func makeBundleFixture(ephemeral: Bool?) throws -> URL {
		let root: URL = FileManager.default
			.temporaryDirectory
			.appending(component: "EphemeralBundleTests-\(UUID().uuidString)")
		let bundle: URL = root.appending(component: "job.bundle")
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		try Data("disk".utf8).write(to: GuestBundleLayout.diskImage(in: bundle))
		try Data("aux".utf8).write(to: GuestBundleLayout.auxiliaryStorage(in: bundle))
		try Data("machine-identifier".utf8).write(to: GuestBundleLayout.machineIdentifier(in: bundle))
		try Data("hardware-model".utf8).write(to: GuestBundleLayout.hardwareModel(in: bundle))
		let metadata: BundleMetadata = .init(
			macAddress: "0a:1b:2c:3d:4e:5f",
			osBuildVersion: "25F80",
			osVersion: "26.5.1",
			restoreImageSHA256: "deadbeef",
			ephemeral: ephemeral
		)
		try JSONEncoder().encode(metadata).write(to: GuestBundleLayout.metadata(in: bundle))
		return root
	}
}
