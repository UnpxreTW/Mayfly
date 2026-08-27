//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit
import NymphKit
import Testing

// MARK: - SessionStoreTests

private final class SessionStoreTests {

	/// spawn wait=true 且 readiness 收斂 → ready + IP、id 為鑄造的 handle、entry 入 table。
	@Test
	private func `spawn blocks to ready and returns ip`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.9") }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let result = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		#expect(result.id == "mfly-test1")
		#expect(result.state == .ready)
		#expect(result.ip == "10.0.0.9")
		#expect(await store.count == 1)
		#expect(engine.lastControl?.recorded.current.started == true)
	}

	/// NY-1：readiness 逾時無 IP → 降級 booting、**不自殺**（VM 未 forceStop / destroy、仍在 table）。
	@Test
	private func `spawn timeout downgrades to booting without killing`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(timeoutOnReady: true) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let result = try await store.spawn(golden: "base", cpus: 4, memoryGiB: 4, wait: true, readinessTimeout: .milliseconds(1))
		#expect(result.state == .booting)
		#expect(result.ip == nil)
		#expect(await store.count == 1)
		let recorded = engine.lastControl?.recorded.current
		#expect(recorded?.forceStopped == false)
		#expect(recorded?.destroyed == false)
	}

	/// 沒接網路的 guest：readiness 收斂但解不出 IP → 仍回 ready（狀態向控制面查、不由 IP 反推）。
	@Test
	private func `spawn reports ready even without an ip`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(readyIP: nil) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let result: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		#expect(result.state == .ready)
		#expect(result.ip == nil)
		#expect(await store.count == 1)
	}

	/// wait=false → 即回 booting、無 IP（VM 續開機、client 自輪詢）。
	@Test
	private func `spawn no wait returns booting immediately`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let result = try await store.spawn(golden: "base", cpus: 4, memoryGiB: 4, wait: false, readinessTimeout: .seconds(1))
		#expect(result.state == .booting)
		#expect(result.ip == nil)
		#expect(engine.lastControl?.recorded.current.started == true)
	}

	/// 達併發上限 → admissionDenied（帶上限值）；上限內先前的 session 不受影響。
	@Test
	private func `admission denied beyond max sessions`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, maxSessions: 1, makeHandle: sequentialHandles())
		_ = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		await #expect(throws: NymphError.admissionDenied(limit: 1)) {
			try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		}
		#expect(await store.count == 1)
	}

	/// execute 路由到對應 control、回其結果；exit code 原樣（資料）。
	@Test
	private func `execute routes to control and returns result`() async throws {
		let outcome: Result<GuestExecResult, NymphError> = .success(GuestExecResult(standardOutput: "hi\n", standardError: "e", exitCode: 7))
		let engine: FakeGuestEngine = .init { FakeGuestControl(execOutcome: outcome) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: true, readinessTimeout: .seconds(1))
		let result = try await store.execute(id: spawn.id, command: ["echo", "hi"], timeout: nil, standardInput: nil, workingDirectory: nil, environment: [:])
		#expect(result.standardOutput == "hi\n")
		#expect(result.standardError == "e")
		#expect(result.exit == 7)
		#expect(engine.lastControl?.recorded.current.execCommands == [["echo", "hi"]])
	}

	/// execute 未知 id → noSuchID。
	@Test
	private func `execute unknown id throws no such id`() async throws {
		let store: SessionStore = .init(engine: FakeGuestEngine())
		await #expect(throws: NymphError.noSuchID("ghost")) {
			try await store.execute(id: "ghost", command: ["x"], timeout: nil, standardInput: nil, workingDirectory: nil, environment: [:])
		}
	}

	/// execute 傳輸層失敗（control 擲 NymphError）原樣往上傳。
	@Test
	private func `execute transport failure propagates`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(execOutcome: .failure(.transportFailure("denied"))) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: true, readinessTimeout: .seconds(1))
		await #expect(throws: NymphError.transportFailure("denied")) {
			try await store.execute(id: spawn.id, command: ["x"], timeout: nil, standardInput: nil, workingDirectory: nil, environment: [:])
		}
	}

	/// list：預設濾掉已 stopped 未回收者、`all` 全列。
	@Test
	private func `list hides stopped unless all`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		_ = try await store.spawn(golden: "live", cpus: 1, memoryGiB: 1, wait: true, readinessTimeout: .seconds(1))
		// 第二台以 stateOverride=.stopped 模擬「跑完自停、未回收」。
		let stoppedEngine: FakeGuestEngine = .init { FakeGuestControl(stateOverride: .stopped) }
		let store2: SessionStore = .init(engine: stoppedEngine, makeHandle: sequentialHandles())
		_ = try await store2.spawn(golden: "gone", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		#expect(await store2.list(all: false).sessions.isEmpty)
		#expect(await store2.list(all: true).sessions.count == 1)
		#expect(await store.list(all: false).sessions.count == 1)
	}

	/// status：回摘要（含 golden / cpus / mem）；未知 id → noSuchID。
	@Test
	private func `status returns summary and unknown throws`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.9") }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 3, memoryGiB: 5, wait: true, readinessTimeout: .seconds(1))
		let status = try await store.status(id: spawn.id)
		#expect(status.summary.id == spawn.id)
		#expect(status.summary.state == .ready)
		#expect(status.summary.ip == "10.0.0.9")
		#expect(status.summary.golden == "base")
		#expect(status.summary.cpus == 3)
		#expect(status.summary.memoryGiB == 5)
		await #expect(throws: NymphError.noSuchID("ghost")) {
			try await store.status(id: "ghost")
		}
	}

	/// uptime = clock 步進差（createdAt vs 查詢時刻）。
	@Test
	private func `uptime reflects clock advance`() async throws {
		let engine: FakeGuestEngine = .init()
		let clock: @Sendable () -> Date = steppingClock(start: Date(timeIntervalSince1970: 1000), step: 5)
		let store: SessionStore = .init(engine: engine, clock: clock, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		let status = try await store.status(id: spawn.id)
		#expect(status.summary.uptimeSeconds == 5)
	}

	/// destroy force：forceStop + destroyClone + 移出 table；重複 destroy → noSuchID。
	@Test
	private func `destroy force stops reaps and removes`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: true, readinessTimeout: .seconds(1))
		let result = try await store.destroy(id: spawn.id, force: true)
		#expect(result.destroyed == true)
		#expect(await store.count == 0)
		let recorded = engine.lastControl?.recorded.current
		#expect(recorded?.forceStopped == true)
		#expect(recorded?.destroyed == true)
		await #expect(throws: NymphError.noSuchID(spawn.id)) {
			try await store.destroy(id: spawn.id, force: true)
		}
	}

	/// destroy force=false：走優雅停機（ensureStopped）而非硬停。
	@Test
	private func `destroy graceful uses ensure stopped`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		_ = try await store.destroy(id: spawn.id, force: false)
		let recorded = engine.lastControl?.recorded.current
		#expect(recorded?.gracefulStopped == true)
		#expect(recorded?.forceStopped == false)
	}

	/// drain：每 session forceStop + destroyClone、清空 table。
	@Test
	private func `drain stops and reaps all sessions`() async throws {
		let controls: Locked<[FakeGuestControl]> = .init([])
		let engine: FakeGuestEngine = .init {
			let control: FakeGuestControl = .init()
			controls.withLock { $0.append(control) }
			return control
		}
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		_ = try await store.spawn(golden: "a", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		_ = try await store.spawn(golden: "b", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		await store.drain()
		#expect(await store.count == 0)
		for control in controls.current {
			#expect(control.recorded.current.forceStopped == true)
			#expect(control.recorded.current.destroyed == true)
		}
	}

	/// handle 把 NymphError 映成 tool-error envelope（穩定 code）、不擲出。
	@Test
	private func `handle maps engine error to tool error`() async {
		let engine: FakeGuestEngine = .init(provisionError: .goldenNotFound("nope"))
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let response = await store.handle(.spawn(SpawnParams(golden: "nope")))
		guard case let .toolError(error) = response else {
			Issue.record("預期 toolError、得 \(response)")
			return
		}
		#expect(error.code == "golden_not_found")
	}

	/// 路由：`kind` 決定用哪顆引擎——linux 請求進 linux 引擎、mac 引擎完全沒被碰。
	@Test
	private func `spawn routes to the engine registered for the kind`() async throws {
		let mac: FakeGuestEngine = .init()
		let linux: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.42") }
		let store: SessionStore = .init(engines: [.mac: mac, .linux: linux], makeHandle: sequentialHandles())
		let result: SpawnResult = try await store.spawn(
			golden: "alpine",
			kind: .linux,
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		#expect(result.ip == "10.0.0.42")
		#expect(linux.lastControl?.recorded.current.started == true)
		#expect(mac.lastControl == nil)
	}

	/// 沒註冊該 kind 的引擎 → engineUnavailable（不退回別顆引擎代打），對外 code 穩定。
	@Test
	private func `spawn without an engine for the kind fails loudly`() async {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let response: NymphResponse = await store.handle(.spawn(SpawnParams(golden: "alpine", kind: .linux)))
		guard case let .toolError(error) = response else {
			Issue.record("預期 toolError、得 \(response)")
			return
		}
		#expect(error.code == "engine_unavailable")
		#expect(engine.lastControl == nil)
		#expect(await store.count == 0)
	}

	/// 不帶 kind 的請求（舊 client）照舊落在 mac 引擎。
	@Test
	private func `spawn defaults to the mac engine`() async {
		let mac: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.9") }
		let linux: FakeGuestEngine = .init()
		let store: SessionStore = .init(engines: [.mac: mac, .linux: linux], makeHandle: sequentialHandles())
		let response: NymphResponse = await store.handle(.spawn(SpawnParams(golden: "base", wait: true)))
		guard case let .spawn(result) = response else {
			Issue.record("預期 spawn 回應、得 \(response)")
			return
		}
		#expect(result.ip == "10.0.0.9")
		#expect(linux.lastControl == nil)
	}

	/// handle 分派 spawn 成功 → spawn 回應。
	@Test
	private func `handle dispatches spawn success`() async {
		let engine: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.9") }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let response = await store.handle(.spawn(SpawnParams(golden: "base", wait: true)))
		guard case let .spawn(result) = response else {
			Issue.record("預期 spawn 回應、得 \(response)")
			return
		}
		#expect(result.state == .ready)
		#expect(result.ip == "10.0.0.9")
	}

	/// clone 登記：spawn 後登記檔含 clonePath、destroy 後移除。
	@Test
	private func `clone registry tracks spawn and destroy`() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "nymphtest-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let registry: CloneRegistry = .init(fileURL: directory.appending(component: "clones.registry"))
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, cloneRegistry: registry, makeHandle: sequentialHandles())
		let spawn = try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
		let clonePath: String = try #require(engine.provisionedPaths.current.first).standardizedFileURL.path
		let afterSpawn: String = try String(contentsOf: registry.fileURL, encoding: .utf8)
		#expect(afterSpawn.contains(clonePath))
		_ = try await store.destroy(id: spawn.id, force: true)
		let afterDestroy: String = (try? String(contentsOf: registry.fileURL, encoding: .utf8)) ?? ""
		#expect(!afterDestroy.contains(clonePath))
	}
}
