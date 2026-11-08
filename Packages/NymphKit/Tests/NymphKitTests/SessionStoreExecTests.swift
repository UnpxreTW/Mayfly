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

// MARK: - SessionStoreExecTests

private final class SessionStoreExecTests {

	/// 背景 exec：送出即回 id；跑著時取得到目前輸出；結束後帶結束碼與結束時間。
	@Test
	private func `detached exec reports output while running and exit after it ends`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let submit: ExecSubmitResult = try await submitDetached(store, id: session.id)
		let execution: FakeExecution = try #require(engine.lastControl?.executions.current.first)
		execution.standardOutput.append(Data("step 1\n".utf8))
		let running: ExecOutputResult = try await store.execOutput(execID: submit.execID, tailBytes: nil)
		#expect(running.state == .running)
		#expect(running.standardOutput == "step 1\n")
		#expect(running.lastOutputAt != nil)
		#expect(running.exit == nil)
		#expect(running.endedAt == nil)
		execution.finish(.exited(3))
		let ended: ExecOutputResult = try await waitUntilEnded(store, execID: submit.execID)
		#expect(ended.state == .exited)
		#expect(ended.exit == 3)
		#expect(ended.endedAt != nil)
		#expect(ended.standardOutput == "step 1\n")
	}

	/// 查無的 exec id：取輸出與取消都回 exec_not_found。
	@Test
	private func `unknown exec id is not found`() async {
		let store: SessionStore = .init(engine: FakeGuestEngine(), makeHandle: sequentialHandles())
		await #expect(throws: NymphError.execNotFound("exec-none")) {
			try await store.execOutput(execID: "exec-none", tailBytes: nil)
		}
		await #expect(throws: NymphError.execNotFound("exec-none")) {
			try await store.execCancel(execID: "exec-none")
		}
	}

	/// 取消：等命令收尾後回 cancelled；已結束的再取消回 exec_not_running。
	@Test
	private func `cancel ends a running exec and rejects a second cancel`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let submit: ExecSubmitResult = try await submitDetached(store, id: session.id)
		let cancelled: ExecOutputResult = try await store.execCancel(execID: submit.execID)
		#expect(cancelled.state == .cancelled)
		#expect(cancelled.endedAt != nil)
		#expect(engine.lastControl?.executions.current.first?.cancelCount == 1)
		await #expect(throws: NymphError.execNotRunning(submit.execID)) {
			try await store.execCancel(execID: submit.execID)
		}
	}

	/// destroy 取消 session 上的背景 exec：以 cancelled 收尾、紀錄留著可查。
	@Test
	private func `destroy ends a running detached exec as cancelled`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let submit: ExecSubmitResult = try await submitDetached(store, id: session.id)
		_ = try await store.destroy(id: session.id, force: true)
		let ended: ExecOutputResult = try await waitUntilEnded(store, execID: submit.execID)
		#expect(ended.state == .cancelled)
		#expect(ended.endedAt != nil)
	}

	/// 背景 exec 只在 session 活著時佔席：session 被 destroy 後，命令還沒收尾也不擋下一個 spawn。
	@Test
	private func `a detached exec on a destroyed session does not hold a seat`() async throws {
		let engine: FakeGuestEngine = .init {
			FakeGuestControl(skipCancellation: true)
		}
		let store: SessionStore = .init(engine: engine, maxSessions: 1, makeHandle: sequentialHandles())
		let first: SpawnResult = try await spawn(store)
		let submit: ExecSubmitResult = try await submitDetached(store, id: first.id)
		await #expect(throws: NymphError.admissionDenied(limit: 1)) {
			try await self.spawn(store)
		}
		_ = try await store.destroy(id: first.id, force: true)
		let second: SpawnResult = try await spawn(store)
		#expect(second.id != first.id)
		let running: ExecOutputResult = try await store.execOutput(execID: submit.execID, tailBytes: nil)
		#expect(running.state == .running)
	}

	/// 啟動還沒回時 session 就被 destroy：destroy 那一趟的取消看不到這條命令，登記時要補送取消。
	@Test
	private func `a detached exec started across a destroy is cancelled once registered`() async throws {
		let gate: Gate = .init()
		let engine: FakeGuestEngine = .init { FakeGuestControl(startExecGate: gate) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let pending: Task<ExecSubmitResult, any Error> = Task {
			try await store.executeDetached(
				id: session.id,
				command: ["sleep", "100"],
				timeout: nil,
				standardInput: nil,
				workingDirectory: nil,
				environment: [:]
			)
		}
		await gate.waitUntilEntered()
		_ = try await store.destroy(id: session.id, force: true)
		gate.release()
		let submit: ExecSubmitResult = try await pending.value
		let ended: ExecOutputResult = try await waitUntilEnded(store, execID: submit.execID)
		#expect(ended.state == .cancelled)
		#expect(engine.lastControl?.executions.current.first?.cancelCount == 1)
	}

	/// tailBytes：只回最後那段、切點不落在多 byte 字元中間、標為截斷。
	@Test
	private func `tail bytes cuts on a character boundary`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let submit: ExecSubmitResult = try await submitDetached(store, id: session.id)
		let execution: FakeExecution = try #require(engine.lastControl?.executions.current.first)
		execution.standardOutput.append(Data("ab中文".utf8))
		let tail: ExecOutputResult = try await store.execOutput(execID: submit.execID, tailBytes: 4)
		#expect(tail.standardOutput == "文")
		#expect(tail.standardOutputTruncated)
		let whole: ExecOutputResult = try await store.execOutput(execID: submit.execID, tailBytes: nil)
		#expect(whole.standardOutput == "ab中文")
		#expect(!whole.standardOutputTruncated)
	}

	/// 已結束的紀錄超過上限時，先淘汰最早結束的。
	@Test
	private func `finished records beyond the limit are evicted oldest first`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		var execIDs: [String] = []
		for _ in 0 ..< 257 {
			let submit: ExecSubmitResult = try await submitDetached(store, id: session.id)
			execIDs.append(submit.execID)
			_ = try await store.execCancel(execID: submit.execID)
		}
		await #expect(throws: NymphError.execNotFound(execIDs[0])) {
			try await store.execOutput(execID: execIDs[0], tailBytes: nil)
		}
		#expect(try await store.execOutput(execID: execIDs[1], tailBytes: nil).state == .cancelled)
	}

	/// 啟動失敗原樣擲出，經 socket 面映成 tool-error。
	@Test
	private func `start failure surfaces as a tool error`() async throws {
		let engine: FakeGuestEngine = .init { FakeGuestControl(startExecError: .notReady) }
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		let response: NymphResponse = await store.handle(.executeDetached(ExecuteParams(id: session.id, command: ["true"])))
		guard case let .toolError(error) = response else {
			Issue.record("預期 toolError、得 \(response)")
			return
		}
		#expect(error.code == "not_ready")
	}

	/// socket 面：三個請求分派到對應方法。
	@Test
	private func `handle dispatches detached exec requests`() async throws {
		let engine: FakeGuestEngine = .init()
		let store: SessionStore = .init(engine: engine, makeHandle: sequentialHandles())
		let session: SpawnResult = try await spawn(store)
		guard
			case let .execSubmit(submit) = await store.handle(.executeDetached(ExecuteParams(
				id: session.id,
				command: ["true"]
			)))
		else {
			Issue.record("預期 execSubmit")
			return
		}
		guard case let .execOutput(output) = await store.handle(.execOutput(ExecOutputParams(execID: submit.execID))) else {
			Issue.record("預期 execOutput")
			return
		}
		#expect(output.state == .running)
		guard case let .execCancel(final) = await store.handle(.execCancel(ExecCancelParams(execID: submit.execID))) else {
			Issue.record("預期 execCancel")
			return
		}
		#expect(final.state == .cancelled)
	}

	// MARK: Private

	/// 開一台 macOS session（不等 readiness）。
	private func spawn(_ store: SessionStore) async throws -> SpawnResult {
		try await store.spawn(golden: "base", cpus: 1, memoryGiB: 1, wait: false, readinessTimeout: .seconds(1))
	}

	/// 送一條背景 exec。
	private func submitDetached(_ store: SessionStore, id: String) async throws -> ExecSubmitResult {
		try await store.executeDetached(
			id: id,
			command: ["sleep", "100"],
			timeout: nil,
			standardInput: nil,
			workingDirectory: nil,
			environment: [:]
		)
	}

	/// 輪詢到背景 exec 結束（終局由背景 task 記入，需讓出執行權等它）。
	private func waitUntilEnded(_ store: SessionStore, execID: String) async throws -> ExecOutputResult {
		for _ in 0 ..< 2000 {
			let output: ExecOutputResult = try await store.execOutput(execID: execID, tailBytes: nil)
			if output.state != .running {
				return output
			}
			try await Task.sleep(for: .milliseconds(1))
		}
		Issue.record("背景 exec 未在時限內結束")
		return try await store.execOutput(execID: execID, tailBytes: nil)
	}
}
