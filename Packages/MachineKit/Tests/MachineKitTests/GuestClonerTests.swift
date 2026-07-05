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

private final class GuestClonerTests {

	/// clone 後五件套齊、disk 內容與 golden 相同（CoW 複本完整性）。
	@Test
	private func `clone copies all bundle files`() throws {
		let fixture = try makeGoldenFixture()
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		let clone: EphemeralBundle = try cloner.clone(fixture.golden, to: destination)
		for name in [
			GuestBundleLayout.diskImageName,
			GuestBundleLayout.auxiliaryStorageName,
			GuestBundleLayout.machineIdentifierName,
			GuestBundleLayout.hardwareModelName,
			GuestBundleLayout.metadataName
		] {
			#expect(FileManager.default.fileExists(atPath: clone.bundle.appending(component: name).path))
		}
		let goldenDisk = try Data(contentsOf: GuestBundleLayout.diskImage(in: fixture.golden.bundle))
		let cloneDisk = try Data(contentsOf: GuestBundleLayout.diskImage(in: clone.bundle))
		#expect(goldenDisk == cloneDisk)
	}

	/// clone 的 MAC 換成注入值、標上 ephemeral、其餘 metadata 欄位原樣；golden 的
	/// metadata 不動（也不會沾到 ephemeral 標記）。
	@Test
	private func `clone regenerates mac marks ephemeral and preserves other metadata`() throws {
		let fixture = try makeGoldenFixture()
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		let clone: EphemeralBundle = try cloner.clone(fixture.golden, to: destination)

		let cloneMetadata = try decodeMetadata(in: clone.bundle)
		#expect(cloneMetadata.macAddress == "02:00:00:00:00:99")
		#expect(cloneMetadata.ephemeral == true)
		#expect(cloneMetadata.osBuildVersion == "25F80")
		#expect(cloneMetadata.osVersion == "26.5.1")
		#expect(cloneMetadata.restoreImageSHA256 == "deadbeef")

		let goldenMetadata = try decodeMetadata(in: fixture.golden.bundle)
		#expect(goldenMetadata.macAddress == "0a:1b:2c:3d:4e:5f")
		#expect(goldenMetadata.ephemeral == nil)
	}

	/// 目的地已存在 → `destinationExists`、絕不覆蓋。
	@Test
	private func `clone refuses existing destination`() throws {
		let fixture = try makeGoldenFixture()
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "taken.bundle")
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		#expect(throws: GuestClonerError.destinationExists(destination)) {
			try cloner.clone(fixture.golden, to: destination)
		}
	}

	/// 來源不存在 → `sourceMissing`。
	@Test
	private func `clone missing source maps source missing`() throws {
		let root: URL = makeTestRoot()
		defer { removeFixture(root) }
		let missing: URL = root.appending(component: "gone.bundle")
		let destination: URL = root.appending(component: "job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		#expect(throws: GuestClonerError.sourceMissing(missing)) {
			try cloner.clone(GoldenBundle(bundle: missing), to: destination)
		}
	}

	/// clonefile 之後身份再生失敗（缺 metadata.json）→ 半成品目的地整份收掉。
	@Test
	private func `clone failure after copy removes partial destination`() throws {
		let fixture = try makeGoldenFixture(withMetadata: false)
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		#expect(throws: (any Error).self) {
			try cloner.clone(fixture.golden, to: destination)
		}
		#expect(!FileManager.default.fileExists(atPath: destination.path))
	}

	/// destroy 移除 clone、golden 不動。
	@Test
	private func `destroy removes clone and leaves golden intact`() throws {
		let fixture = try makeGoldenFixture()
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		let clone: EphemeralBundle = try cloner.clone(fixture.golden, to: destination)
		try cloner.destroy(clone)
		#expect(!FileManager.default.fileExists(atPath: destination.path))
		#expect(FileManager.default.fileExists(atPath: fixture.golden.bundle.path))
	}

	/// 預設 MAC 產生器：格式 6 組小寫 hex、local bit 置 1、multicast bit 清 0、
	/// 兩次呼叫不同（隨機性 smoke）。
	@Test
	private func `default mac generator emits locally administered unicast`() throws {
		let mac: String = GuestCloner.randomLocallyAdministeredMACAddress()
		let segments = mac.split(separator: ":")
		#expect(segments.count == 6)
		#expect(segments.allSatisfy { $0.count == 2 && $0 == $0.lowercased() })
		let firstByte = try #require(UInt8(segments[0], radix: 16))
		#expect(firstByte & 0b0000_0010 == 0b0000_0010)
		#expect(firstByte & 0b0000_0001 == 0)
		#expect(mac != GuestCloner.randomLocallyAdministeredMACAddress())
	}

	/// errno → 型別化錯誤的映射表：ENOENT 依 `sourceExists` 消歧成兩義、
	/// EEXIST / EXDEV / ENOTSUP / 其他。
	@Test
	private func `errno mapping covers clone failure taxonomy`() {
		let source: URL = .init(fileURLWithPath: "/src")
		let destination: URL = .init(fileURLWithPath: "/dst")
		#expect(GuestClonerError.map(
			errno: ENOENT,
			source: source,
			destination: destination,
			sourceExists: false
		) == .sourceMissing(source))
		#expect(GuestClonerError.map(
			errno: ENOENT,
			source: source,
			destination: destination,
			sourceExists: true
		) == .destinationParentMissing(destination))
		#expect(GuestClonerError.map(
			errno: EEXIST,
			source: source,
			destination: destination,
			sourceExists: true
		) == .destinationExists(destination))
		#expect(GuestClonerError.map(
			errno: EXDEV,
			source: source,
			destination: destination,
			sourceExists: true
		) == .crossVolume(source: source, destination: destination))
		#expect(GuestClonerError.map(
			errno: ENOTSUP,
			source: source,
			destination: destination,
			sourceExists: true
		) == .copyOnWriteUnsupported(destination))
		#expect(GuestClonerError.map(
			errno: EIO,
			source: source,
			destination: destination,
			sourceExists: true
		) == .cloneFailed(errno: EIO))
	}

	/// 目的地父目錄不存在（clonefile 同樣回 ENOENT）→ 消歧成 `destinationParentMissing`、
	/// 不誣賴完好的 golden。
	@Test
	private func `clone missing destination parent maps destination parent missing`() throws {
		let fixture = try makeGoldenFixture()
		defer { removeFixture(fixture.root) }
		let destination: URL = fixture.root.appending(component: "no-such-dir/job.bundle")
		let cloner: GuestCloner = .init(makeMACAddress: { "02:00:00:00:00:99" })
		#expect(throws: GuestClonerError.destinationParentMissing(destination)) {
			try cloner.clone(fixture.golden, to: destination)
		}
	}

	/// 測試專用暫存根目錄（每測一個、defer 清除）。
	private func makeTestRoot() -> URL {
		FileManager.default
			.temporaryDirectory
			.appending(component: "GuestClonerTests-\(UUID().uuidString)")
	}

	/// 造一份最小 golden fixture：五件套（可選缺 metadata.json 以測失敗清理）。
	/// GoldenBundle 的 internal init 由 @testable 取得——僅測試能鑄、不破壞型別閘門。
	private func makeGoldenFixture(withMetadata: Bool = true) throws -> (golden: GoldenBundle, root: URL) {
		let root: URL = makeTestRoot()
		let bundle: URL = root.appending(component: "golden.bundle")
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		try Data("disk-bytes".utf8).write(to: GuestBundleLayout.diskImage(in: bundle))
		try Data("aux".utf8).write(to: GuestBundleLayout.auxiliaryStorage(in: bundle))
		try Data("machine-identifier".utf8).write(to: GuestBundleLayout.machineIdentifier(in: bundle))
		try Data("hardware-model".utf8).write(to: GuestBundleLayout.hardwareModel(in: bundle))
		if withMetadata {
			let metadata: BundleMetadata = .init(
				macAddress: "0a:1b:2c:3d:4e:5f",
				osBuildVersion: "25F80",
				osVersion: "26.5.1",
				restoreImageSHA256: "deadbeef"
			)
			try JSONEncoder().encode(metadata).write(to: GuestBundleLayout.metadata(in: bundle))
		}
		return (GoldenBundle(bundle: bundle), root)
	}

	/// 讀回 bundle 內 metadata.json。
	private func decodeMetadata(in bundle: URL) throws -> BundleMetadata {
		try JSONDecoder().decode(BundleMetadata.self, from: Data(contentsOf: GuestBundleLayout.metadata(in: bundle)))
	}

	/// 清 fixture 根目錄（best-effort）。
	private func removeFixture(_ root: URL) {
		try? FileManager.default.removeItem(at: root)
	}
}
