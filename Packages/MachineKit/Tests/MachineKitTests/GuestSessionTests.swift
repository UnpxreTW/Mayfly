//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

#if arch(arm64)

@testable import MachineKit
import Foundation
import Testing

private final class GuestSessionTests {

	/// init 只解 metadata（不碰 VZ）：佈局完整的 fixture 建得起 session、狀態 idle。
	@Test
	private func `init decodes metadata without touching vz`() async throws {
		let fixture = try makeEphemeralFixture()
		defer { try? FileManager.default.removeItem(at: fixture.root) }
		let session: GuestSession = try .init(bundle: fixture.clone)
		#expect(await session.state == .idle)
	}

	/// 缺 metadata 的 bundle → init 就擲錯（佈局錯誤在建 session 時擋下）。
	@Test
	private func `init throws when metadata missing`() throws {
		let fixture = try makeEphemeralFixture(withMetadata: false)
		defer { try? FileManager.default.removeItem(at: fixture.root) }
		#expect(throws: (any Error).self) {
			try GuestSession(bundle: fixture.clone)
		}
	}

	/// 未 start 就等 readiness → notStarted。
	@Test
	private func `wait until ready before start throws not started`() async throws {
		let fixture = try makeEphemeralFixture()
		defer { try? FileManager.default.removeItem(at: fixture.root) }
		let session: GuestSession = try .init(bundle: fixture.clone)
		await #expect(throws: GuestSessionError.notStarted) {
			try await session.waitUntilReady()
		}
	}

	/// 未 start 就 forceStop → notStarted。
	@Test
	private func `force stop before start throws not started`() async throws {
		let fixture = try makeEphemeralFixture()
		defer { try? FileManager.default.removeItem(at: fixture.root) }
		let session: GuestSession = try .init(bundle: fixture.clone)
		await #expect(throws: GuestSessionError.notStarted) {
			try await session.forceStop()
		}
	}

	/// start 失敗（fixture 的身份檔是假 bytes、VZ 解不開）→ 錯誤上拋、狀態停在
	/// idle；一次性生命週期：重呼 start → alreadyStarted，且失敗後引用已回滾——
	/// waitUntilStopped / forceStop 一致擲 notStarted（不對從未跑起的 VM 永久等）。
	@Test
	private func `start failure keeps idle and latches already started`() async throws {
		let fixture = try makeEphemeralFixture()
		defer { try? FileManager.default.removeItem(at: fixture.root) }
		let session: GuestSession = try .init(bundle: fixture.clone)
		await #expect(throws: (any Error).self) {
			try await session.start()
		}
		#expect(await session.state == .idle)
		await #expect(throws: GuestSessionError.alreadyStarted) {
			try await session.start()
		}
		await #expect(throws: GuestSessionError.notStarted) {
			try await session.waitUntilStopped()
		}
		await #expect(throws: GuestSessionError.notStarted) {
			try await session.forceStop()
		}
	}

	/// 造一份佈局完整（身份檔為假 bytes）的可拋 bundle fixture。
	/// EphemeralBundle 的 internal init 由 @testable 取得——僅測試能鑄。
	private func makeEphemeralFixture(withMetadata: Bool = true) throws -> (clone: EphemeralBundle, root: URL) {
		let root: URL = FileManager.default
			.temporaryDirectory
			.appending(component: "GuestSessionTests-\(UUID().uuidString)")
		let bundle: URL = root.appending(component: "job.bundle")
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		try Data("disk".utf8).write(to: GuestBundleLayout.diskImage(in: bundle))
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
		return (EphemeralBundle(bundle: bundle), root)
	}
}

#endif
