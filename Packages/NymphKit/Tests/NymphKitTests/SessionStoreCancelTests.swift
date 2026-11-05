//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

// MARK: - SessionStoreCancelTests

private final class SessionStoreCancelTests {

	/// destroy 停機之前先取消該 session 上進行中的命令（強制與優雅兩種停法皆然）。
	@Test
	private func `destroy cancels running commands before stopping the guest`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let forced: SpawnResult = try await spawn(store)
		_ = try await store.destroy(id: forced.id, force: true)
		#expect(engine.lastControl?.recorded.current.stopSequence == ["cancel", "forceStop"])
		let graceful: SpawnResult = try await spawn(store)
		_ = try await store.destroy(id: graceful.id, force: false)
		#expect(engine.lastControl?.recorded.current.stopSequence == ["cancel", "gracefulStop"])
	}

	/// drain 同樣在停機前取消。
	@Test
	private func `drain cancels running commands before stopping the guest`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		_ = try await spawn(store)
		await store.drain()
		#expect(engine.lastControl?.recorded.current.stopSequence == ["cancel", "forceStop"])
	}

	/// 取消的終局對外是穩定的 `cancelled` 碼。
	@Test
	private func `cancelled exec maps to a stable tool error code`() {
		#expect(ToolError(.execCancelled).code == "cancelled")
	}

	// MARK: Private

	/// 開一台 macOS session（不等 readiness）。
	private func spawn(_ store: SessionStore) async throws -> SpawnResult {
		try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
	}
}
