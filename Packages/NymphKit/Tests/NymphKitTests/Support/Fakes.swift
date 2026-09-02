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

/// 極簡上鎖封套——fake 需在跨隔離（actor 呼叫、背景 Task）間累積呼叫紀錄，用 NSLock 護
/// 一份可變值即可，避免測試依賴具體並行原語。
final class Locked<Value>: @unchecked Sendable {

	init(_ value: Value) {
		self.value = value
	}

	@discardableResult
	func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(&value)
	}

	var current: Value {
		withLock { $0 }
	}

	private let lock: NSLock = .init()

	private var value: Value
}

/// 遞增 handle 產生器（確定序 `mfly-testN`）——把 `SessionStore` 的 id 鑄造變確定、方便斷言。
func sequentialHandles() -> @Sendable () -> String {
	let counter: Locked<Int> = .init(0)
	return {
		let next: Int = counter.withLock {
			$0 += 1
			return $0
		}
		return "mfly-test\(next)"
	}
}

/// 固定步進的時鐘：第 i 次呼叫回 `start + i * step`（i 從 0）——讓 uptime 可預期。
func steppingClock(start: Date, step: TimeInterval) -> @Sendable () -> Date {
	let counter: Locked<Int> = .init(0)
	return {
		let index: Int = counter.withLock {
			let value: Int = $0
			$0 += 1
			return value
		}
		return start.addingTimeInterval(Double(index) * step)
	}
}

/// 記憶體 sink：把事件依序收進 `Locked` 陣列——驗事件序與欄位、不驗秒數（秒數是真實時鐘、
/// 不可預期）。
internal func recordingLogSink() -> (sink: SessionLogSink, events: Locked<[SessionLogEvent]>) {
	let events: Locked<[SessionLogEvent]> = .init([])
	let sink: SessionLogSink = { event in
		events.withLock { $0.append(event) }
	}
	return (sink, events)
}

/// 假 VM 控制面：可配 readiness / start / exec 結果，記錄 start / stop / destroy / exec 呼叫——把
/// `SessionStore` 的編排與真 VM / 真 SSH 隔開來測。
final class FakeGuestControl: GuestControl, @unchecked Sendable {

	struct Recorded {

		var started = false

		var forceStopped = false

		var gracefulStopped = false

		var destroyed = false

		var state: SessionState = .idle

		var execCommands: [[String]] = []
	}

	init(
		readyIP: String? = "10.0.0.9",
		timeoutOnReady: Bool = false,
		stateOverride: SessionState? = nil,
		execOutcome: Swift.Result<GuestExecResult, NymphError> = .success(GuestExecResult(standardOutput: "ok\n", standardError: "", exitCode: 0)),
		startError: NymphError? = nil
	) {
		self.readyIP = readyIP
		self.timeoutOnReady = timeoutOnReady
		self.stateOverride = stateOverride
		self.execOutcome = execOutcome
		self.startError = startError
	}

	let recorded: Locked<Recorded> = .init(Recorded())

	func start() async throws {
		if let startError {
			throw startError
		}
		recorded.withLock {
			$0.started = true
			$0.state = .booting
		}
	}

	func waitUntilReady() async throws -> String? {
		if timeoutOnReady {
			recorded.withLock { $0.state = .booting }
			return nil
		}
		recorded.withLock { $0.state = .ready }
		return readyIP
	}

	func currentState() async -> SessionState {
		stateOverride ?? recorded.current.state
	}

	func currentIP() async -> String? {
		(stateOverride ?? recorded.current.state) == .ready ? readyIP : nil
	}

	func forceStop() async throws {
		recorded.withLock {
			$0.forceStopped = true
			$0.state = .stopped
		}
	}

	func gracefulStop(within grace: Duration) async throws {
		recorded.withLock {
			$0.gracefulStopped = true
			$0.state = .stopped
		}
	}

	func exec(
		_ command: [String],
		timeout: Duration?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> GuestExecResult {
		recorded.withLock { $0.execCommands.append(command) }
		return try execOutcome.get()
	}

	func destroyClone() throws {
		recorded.withLock { $0.destroyed = true }
	}

	private let readyIP: String?

	private let timeoutOnReady: Bool

	private let stateOverride: SessionState?

	private let execOutcome: Swift.Result<GuestExecResult, NymphError>

	private let startError: NymphError?
}

/// 假引擎：每次 provision 造一個 ``FakeGuestControl`` 並記錄它與 clonePath，供斷言。可配
/// provision 失敗。
final class FakeGuestEngine: GuestEngine, @unchecked Sendable {

	init(
		provisionError: NymphError? = nil,
		makeControl: @escaping @Sendable () -> FakeGuestControl = { FakeGuestControl() }
	) {
		self.provisionError = provisionError
		self.makeControl = makeControl
	}

	let produced: Locked<[FakeGuestControl]> = .init([])

	let provisionedPaths: Locked<[URL]> = .init([])

	func provision(
		golden: String,
		cpus: Int,
		memoryGiB: Int,
		readinessTimeout: Duration
	) async throws -> ProvisionedGuest {
		if let provisionError {
			throw provisionError
		}
		let control: FakeGuestControl = makeControl()
		produced.withLock { $0.append(control) }
		let path: URL = URL(fileURLWithPath: "/tmp/mayfly-fake-clones/\(UUID().uuidString)")
		provisionedPaths.withLock { $0.append(path) }
		return ProvisionedGuest(control: control, goldenAlias: golden, clonePath: path)
	}

	var lastControl: FakeGuestControl? {
		produced.current.last
	}

	private let provisionError: NymphError?

	private let makeControl: @Sendable () -> FakeGuestControl
}

/// 假分派器：回固定回應、記錄收到的請求——`NymphServer` 傳輸整合測試用（脫離 store）。
final class FakeDispatcher: RequestDispatching, @unchecked Sendable {

	init(response: NymphResponse) {
		self.response = response
	}

	let received: Locked<[NymphRequest]> = .init([])

	func handle(_ request: NymphRequest) async -> NymphResponse {
		received.withLock { $0.append(request) }
		return response
	}

	private let response: NymphResponse
}
