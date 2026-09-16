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

/// 半途閘：讓 fake 的某一步停在半途（優雅停機、readiness 等待、exec、狀態查詢），測試因此能在
/// 那段窗口裡插進另一次呼叫（actor 重入），把原本只在真機上偶發的交錯變成確定序。
///
/// 兩道訊號各走一條 `AsyncStream`：`enterAndWait()` 先通知「被閘住的那一步已經走進來了」再等放行，
/// `release()` 放它走完。兩邊誰先到都不會卡住——先 yield 的值進緩衝、先 finish 的串流讓等待
/// 端立刻拿到 nil。
internal final class Gate: Sendable {

	internal init() {
		let entered: Pipe = AsyncStream.makeStream()
		let released: Pipe = AsyncStream.makeStream()
		enteredStream = entered.stream
		enteredContinuation = entered.continuation
		releaseStream = released.stream
		releaseContinuation = released.continuation
	}

	/// 被測那側呼叫：標記已走進被閘住的那一步，然後等測試放行。
	internal func enterAndWait() async {
		enteredContinuation.yield()
		var iterator: AsyncStream<Void>.Iterator = releaseStream.makeAsyncIterator()
		_ = await iterator.next()
	}

	/// 測試側呼叫：等被閘住的那一步真的走進來。
	internal func waitUntilEntered() async {
		var iterator: AsyncStream<Void>.Iterator = enteredStream.makeAsyncIterator()
		_ = await iterator.next()
	}

	/// 測試側呼叫：放被閘住的那一步走完。
	internal func release() {
		releaseContinuation.finish()
	}

	/// 一條訊號線：串流本體與它的送出端。
	private typealias Pipe = (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)

	private let enteredStream: AsyncStream<Void>

	private let enteredContinuation: AsyncStream<Void>.Continuation

	private let releaseStream: AsyncStream<Void>

	private let releaseContinuation: AsyncStream<Void>.Continuation
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
		startError: NymphError? = nil,
		stopGate: Gate? = nil,
		readyGate: Gate? = nil,
		execGate: Gate? = nil,
		stateGate: Gate? = nil
	) {
		self.readyIP = readyIP
		self.timeoutOnReady = timeoutOnReady
		self.stateOverride = stateOverride
		self.execOutcome = execOutcome
		self.startError = startError
		self.stopGate = stopGate
		self.readyGate = readyGate
		self.execGate = execGate
		self.stateGate = stateGate
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
		// 真機上 guest 可能在 readiness 收斂前就自行關機（golden 開機即 panic、跑完就 halt）；掛了
		// 閘的 fake 先把狀態翻成 stopped 再停在這裡，讓測試得以在「spawn 還沒回」那段窗口裡動作。
		if let readyGate {
			recorded.withLock { $0.state = .stopped }
			await readyGate.enterAndWait()
			return nil
		}
		if timeoutOnReady {
			recorded.withLock { $0.state = .booting }
			return nil
		}
		recorded.withLock { $0.state = .ready }
		return readyIP
	}

	func currentState() async -> SessionState {
		// 只擋第一次查詢：准入的計數會在這裡向控制面查狀態，測試要讓「第一個請求數到一半」停住，
		// 但第二個請求必須走得完（`Gate` 的訊號線只供一個等待端，兩邊一起等會壞）。
		if let stateGate, stateGateArmed.withLock({ armed -> Bool in
			defer { armed = false }
			return armed
		}) {
			await stateGate.enterAndWait()
		}
		return stateOverride ?? recorded.current.state
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
		// 真機的停機在狀態翻成 stopped 之後還要跑一段（容器 stop、VM 的 grace），掛了閘的 fake
		// 就停在這裡，讓測試得以在那段窗口裡動作。
		if let stopGate {
			await stopGate.enterAndWait()
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
		// exec 進行中 guest 自行關機：掛了閘的 fake 翻成 stopped 後停在這裡，測試得以在 exec 還沒
		// 回的窗口裡插進別的呼叫。
		if let execGate {
			recorded.withLock { $0.state = .stopped }
			await execGate.enterAndWait()
		}
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

	private let stopGate: Gate?

	private let readyGate: Gate?

	private let execGate: Gate?

	private let stateGate: Gate?

	/// `stateGate` 尚未被用掉（見 ``currentState()``）。
	private let stateGateArmed: Locked<Bool> = .init(true)
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
