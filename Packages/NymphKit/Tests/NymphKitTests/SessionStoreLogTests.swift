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

// MARK: - SessionStoreLogTests

private final class SessionStoreLogTests {

	/// spawn 成功：三段依序記錄、欄位帶 golden／kind／收斂後狀態。
	@Test
	private func `spawn emits provision start ready segments in order`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl(readyIP: "10.0.0.9") }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(recorder.events.current.count == 1)
		#expect(event.operation == .spawn)
		#expect(event.sessionID == "mfly-test1")
		#expect(event.golden == "base")
		#expect(event.kind == .mac)
		#expect(event.segments.map(\.name) == [.provision, .start, .ready])
		#expect(event.outcome == .ok)
		#expect(event.state == .ready)
		#expect(event.exitCode == nil)
	}

	/// `wait=false` 早退：只有 provision／start 兩段、狀態記 booting。
	@Test
	private func `spawn without wait stops at start segment`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: false, readinessTimeout: .seconds(1))
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.segments.map(\.name) == [.provision, .start])
		#expect(event.state == .booting)
		#expect(event.outcome == .ok)
	}

	/// NY-1：readiness 逾時是降級、不是錯誤——三段齊、結果仍 ok、狀態留 booting。
	@Test
	private func `spawn readiness timeout is not an error`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl(timeoutOnReady: true) }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .milliseconds(1))
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.segments.map(\.name) == [.provision, .start, .ready])
		#expect(event.state == .booting)
		#expect(event.outcome == .ok)
	}

	/// provision 就失敗：尚未鑄 handle → 無 id、無段、帶對外錯誤碼。
	@Test
	private func `spawn provision failure emits error without id`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init(provisionError: .goldenNotFound("nope"))
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		await #expect(throws: NymphError.goldenNotFound("nope")) {
			try await store.spawn(golden: "nope", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		}
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.sessionID == nil)
		#expect(event.golden == "nope")
		#expect(event.segments.isEmpty)
		#expect(event.outcome == .error(ToolError(.goldenNotFound("nope"))))
	}

	/// start 失敗：已完成的 provision 段留著、id 已鑄出，session 本身回滾出 table。
	@Test
	private func `spawn start failure keeps provision segment`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl(startError: .internalFailure("boom")) }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		await #expect(throws: NymphError.self) {
			try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		}
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.segments.map(\.name) == [.provision])
		#expect(event.sessionID == "mfly-test1")
		#expect(errorCode(of: event) == "internal_error")
		#expect(await store.count == 0)
	}

	/// 未註冊該 kind 的引擎：連 provision 都沒進去——無段，但請求的 kind 照記。
	@Test
	private func `spawn without engine for kind emits error with kind`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		await #expect(throws: NymphError.engineUnavailable(.linux)) {
			try await store.spawn(golden: "base", kind: .linux, cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		}
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.kind == .linux)
		#expect(event.segments.isEmpty)
		#expect(errorCode(of: event) == "engine_unavailable")
	}

	/// execute 成功：一段 exec、記結束碼與 argv[0]（非零結束碼是資料、不是錯誤）。
	@Test
	private func `execute emits exec segment exit code and argv0`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let outcome: Swift.Result<GuestExecResult, NymphError> = .success(
			GuestExecResult(standardOutput: "", standardError: "", exitCode: 7)
		)
		let engine: FakeGuestEngine = .init { FakeGuestControl(execOutcome: outcome) }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		let spawned: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		_ = try await store.execute(
			id: spawned.id,
			command: ["echo", "hi"],
			timeout: nil,
			standardInput: nil,
			workingDirectory: nil,
			environment: [:]
		)
		let event: SessionLogEvent = try #require(recorder.events.current.last)
		#expect(event.operation == .execute)
		#expect(event.segments.map(\.name) == [.exec])
		#expect(event.exitCode == 7)
		#expect(event.command == "echo")
		#expect(event.outcome == .ok)
	}

	/// execute 傳輸層失敗：exec 段未完成、不入列，也沒有結束碼。
	@Test
	private func `execute transport failure emits error without exec segment`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl(execOutcome: .failure(.transportFailure("denied"))) }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		let spawned: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		await #expect(throws: NymphError.transportFailure("denied")) {
			try await store.execute(
				id: spawned.id,
				command: ["x"],
				timeout: nil,
				standardInput: nil,
				workingDirectory: nil,
				environment: [:]
			)
		}
		let event: SessionLogEvent = try #require(recorder.events.current.last)
		#expect(event.segments.isEmpty)
		#expect(event.exitCode == nil)
		#expect(event.outcome == .error(ToolError(.transportFailure("denied"))))
	}

	/// execute 未知 id：事件仍記下被問的 id，錯誤碼為 no_such_id。
	@Test
	private func `execute unknown id emits no such id`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		await #expect(throws: NymphError.noSuchID("ghost")) {
			try await store.execute(
				id: "ghost",
				command: ["x"],
				timeout: nil,
				standardInput: nil,
				workingDirectory: nil,
				environment: [:]
			)
		}
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.sessionID == "ghost")
		#expect(errorCode(of: event) == "no_such_id")
	}

	/// status 沒有分段可拆——只有總耗時與收斂後狀態。
	@Test
	private func `status emits total only`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		let spawned: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		_ = try await store.status(id: spawned.id)
		let event: SessionLogEvent = try #require(recorder.events.current.last)
		#expect(event.operation == .status)
		#expect(event.segments.isEmpty)
		#expect(event.state == .ready)
	}

	/// destroy：stop 段記錄停機耗時，force 欄分辨硬停與優雅停機。
	@Test
	private func `destroy emits stop segment with force mode`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		let forced: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		_ = try await store.destroy(id: forced.id, force: true)
		let forcedEvent: SessionLogEvent = try #require(recorder.events.current.last)
		#expect(forcedEvent.operation == .destroy)
		#expect(forcedEvent.segments.map(\.name) == [.stop])
		#expect(forcedEvent.force == true)
		let graceful: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		_ = try await store.destroy(id: graceful.id, force: false)
		let gracefulEvent: SessionLogEvent = try #require(recorder.events.current.last)
		#expect(gracefulEvent.segments.map(\.name) == [.stop])
		#expect(gracefulEvent.force == false)
	}

	/// list（app 定時輪詢、會洗版）與 drain（關機收束）刻意不記——事件數不因它們增加。
	@Test
	private func `list and drain emit nothing`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		_ = await store.list(all: true)
		await store.drain()
		#expect(recorder.events.current.count == 1)
	}

	/// 事件時間戳取自注入的時間源、不自己讀系統時鐘。
	@Test
	private func `timestamp comes from the injected clock`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		let event: SessionLogEvent = try #require(recorder.events.current.first)
		#expect(event.timestamp == Date(timeIntervalSince1970: 0))
	}

	/// 事件依操作發生序抵達 sink，同一個 session 的四筆 id 一致。
	@Test
	private func `events arrive in operation order`() async throws {
		let recorder: (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) = recordingLogSink()
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = makeStore(engine: engine, sink: recorder.sink)
		let spawned: SpawnResult = try await store.spawn(
			golden: "base",
			cpus: 2,
			memoryGiB: 2,
			wait: true,
			readinessTimeout: .seconds(1)
		)
		_ = try await store.execute(
			id: spawned.id,
			command: ["echo"],
			timeout: nil,
			standardInput: nil,
			workingDirectory: nil,
			environment: [:]
		)
		_ = try await store.status(id: spawned.id)
		_ = try await store.destroy(id: spawned.id, force: true)
		let events: [SessionLogEvent] = recorder.events.current
		#expect(events.map(\.operation) == [.spawn, .execute, .status, .destroy])
		#expect(events.allSatisfy { $0.sessionID == spawned.id })
	}

	/// 關閉時是零量測：不掛 sink 的一次 spawn 只讀一次時間源（entry 的 createdAt），掛了才
	/// 多讀一次當事件時間戳。這條直接守住「預設關＝零開銷」。
	@Test
	private func `disabled sink adds no clock read`() async throws {
		let withoutSink: Int = try await clockReads(sink: nil)
		let withSink: Int = try await clockReads(sink: recordingLogSink().sink)
		#expect(withoutSink == 1)
		#expect(withSink == withoutSink + 1)
	}

	/// 跑一次 spawn，回報注入的時間源被讀了幾次。
	private func clockReads(sink: SessionLogSink?) async throws -> Int {
		let reads: Locked<Int> = .init(0)
		let engine: FakeGuestEngine = .init { FakeGuestControl() }
		let store: SessionStore = .init(
			engine: engine,
			logSink: sink,
			clock: {
				reads.withLock { $0 += 1 }
				return Date(timeIntervalSince1970: 0)
			},
			makeHandle: sequentialHandles()
		)
		_ = try await store.spawn(golden: "base", cpus: 2, memoryGiB: 2, wait: true, readinessTimeout: .seconds(1))
		return reads.current
	}

	/// 本檔共用的 store：固定時鐘（時間戳可斷言）＋確定序 handle。
	private func makeStore(engine: FakeGuestEngine, sink: @escaping SessionLogSink) -> SessionStore {
		SessionStore(
			engine: engine,
			logSink: sink,
			clock: { Date(timeIntervalSince1970: 0) },
			makeHandle: sequentialHandles()
		)
	}

	/// 取事件的對外錯誤碼；成功事件回 nil。
	private func errorCode(of event: SessionLogEvent) -> String? {
		if case let .error(error) = event.outcome {
			return error.code
		}
		return nil
	}
}
