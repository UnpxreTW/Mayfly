//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

/// nymph daemon 的核心：`id -> SessionEntry` 的 session table（設計 §4.1）。序列化所有對
/// table 的存取（actor），每台 VM 各自活在自己的 ``GuestControl`` 內、彼此獨立。上層
/// 五工具（spawn/execute/list/status/destroy）皆為此 actor 的方法；socket 面經
/// ``RequestDispatching`` 把 ``NymphRequest`` 打進來。
///
/// **不直接觸碰引擎**：全程走 ``GuestEngine`` / ``GuestControl`` 抽象，VM 生命週期與 exec
/// 的真機細節關在 arm64 的 ``RealGuestEngine``；本 actor 的編排（admission、handle 鑄造、
/// spawn 阻塞 / 逾時降級、drain）因此可用 fake 純邏輯單測。
public actor SessionStore {

	// MARK: Public

	/// - Parameters:
	///   - engines: ``GuestKind`` → 該種 guest 的引擎。**未列的 kind 一律擲
	///     ``NymphError/engineUnavailable(_:)``**——不退回任何一顆引擎代打（別的 kind 的
	///     別名餵給錯引擎會靜默開出錯的 guest）。
	///   - maxSessions: 併發 session 上限（admission；設計 §10.4 的最小落地——先做 VM 數
	///     上限，記憶體 / CPU 總量准入留後續）。
	///   - gracePeriod: `destroy force=false` 的優雅停機上限。
	///   - cloneRegistry: 孤兒回收登記（nil＝不登記、僅記憶體 table）。
	///   - clock: 時間源（uptime 計算；測試注入固定值）。
	///   - makeHandle: opaque handle 產生器（測試注入確定序列）。
	public init(
		engines: [GuestKind: any GuestEngine],
		maxSessions: Int = 8,
		gracePeriod: Duration = .seconds(30),
		cloneRegistry: CloneRegistry? = nil,
		clock: @escaping @Sendable () -> Date = { Date() },
		makeHandle: @escaping @Sendable () -> String = { SessionStore.randomHandle() }
	) {
		self.engines = engines
		self.maxSessions = maxSessions
		self.gracePeriod = gracePeriod
		self.cloneRegistry = cloneRegistry
		self.clock = clock
		self.makeHandle = makeHandle
	}

	/// 只掛 macOS 引擎的便利建構（等同 `engines: [.mac: engine]`）——`kind: linux` 的請求
	/// 於此形下擲 ``NymphError/engineUnavailable(_:)``。
	public init(
		engine: any GuestEngine,
		maxSessions: Int = 8,
		gracePeriod: Duration = .seconds(30),
		cloneRegistry: CloneRegistry? = nil,
		clock: @escaping @Sendable () -> Date = { Date() },
		makeHandle: @escaping @Sendable () -> String = { SessionStore.randomHandle() }
	) {
		self.init(
			engines: [.mac: engine],
			maxSessions: maxSessions,
			gracePeriod: gracePeriod,
			cloneRegistry: cloneRegistry,
			clock: clock,
			makeHandle: makeHandle
		)
	}

	/// 隨機 opaque handle：`mfly-` + 8 hex（4 亂數 byte）。對映 Docker container id 心智、
	/// 不含 host 路徑。
	public static func randomHandle() -> String {
		let bytes: [UInt8] = (0 ..< 4).map { _ in UInt8.random(in: .min ... .max) }
		return "mfly-" + bytes.map { String(format: "%02x", $0) }.joined()
	}

	/// clone + boot + 依 NY-1 收斂：`wait=true`（預設）阻塞到 READY、逾時無 IP **降級回
	/// booting 不自殺**（VM 續跑、client 之後以 status 輪詢）；`wait=false` 即回 booting。
	///
	/// 引擎由 `kind` 選定（線協議欄、非別名字面推斷）；該 kind 未註冊引擎時擲
	/// ``NymphError/engineUnavailable(_:)``，不代打、不猜。
	public func spawn(
		golden: String,
		kind: GuestKind = .mac,
		cpus: Int,
		memoryGiB: Int,
		wait: Bool,
		readinessTimeout: Duration
	) async throws -> SpawnResult {
		guard let engine: any GuestEngine = engines[kind] else { throw NymphError.engineUnavailable(kind) }
		guard table.count < maxSessions else {
			throw NymphError.admissionDenied(limit: maxSessions)
		}
		let provisioned: ProvisionedGuest = try await engine.provision(
			golden: golden,
			cpus: cpus,
			memoryGiB: memoryGiB,
			readinessTimeout: readinessTimeout
		)
		let id: String = mintHandle()
		cloneRegistry?.add(provisioned.clonePath)
		table[id] = Entry(
			id: id,
			control: provisioned.control,
			goldenAlias: provisioned.goldenAlias,
			clonePath: provisioned.clonePath,
			cpus: cpus,
			memoryGiB: memoryGiB,
			createdAt: clock()
		)
		do {
			try await provisioned.control.start()
		} catch {
			try? provisioned.control.destroyClone()
			cloneRegistry?.remove(provisioned.clonePath)
			table[id] = nil
			throw NymphError.internalFailure("spawn start failed: \(error)")
		}
		guard wait else {
			return SpawnResult(id: id, state: .booting, ip: nil)
		}
		var ip: String? = (try? await provisioned.control.waitUntilReady()) ?? nil
		// 狀態向控制面查、不由 IP 反推：沒接網路的 guest（Linux 容器即是）readiness 收斂後
		// 仍解不出 IP，用 IP 反推會把已 ready 的 session 回報成 booting，與緊接著的 status
		// 互相矛盾。IP 只是附帶欄位。
		let state: SessionState = await provisioned.control.currentState()
		// 查狀態這一步本身可能讓等待期間才收斂的 guest 升成 ready；此時 IP 要一併補回，
		// 否則回的是「ready 但沒有 IP」——對接著要連線的呼叫端形同無解。
		if state == .ready, ip == nil {
			ip = await provisioned.control.currentIP()
		}
		table[id]?.lastIP = ip
		return SpawnResult(id: id, state: state, ip: ip)
	}

	/// 在既有 session 內 execute（SSH）。no-such-id 擲 ``NymphError/noSuchID(_:)``；傳輸層失敗
	/// 由 ``GuestControl`` 映成 ``NymphError``。exit code 是資料、非零照常回。
	public func execute(
		id: String,
		command: [String],
		timeout: Duration?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> ExecuteResult {
		guard let entry = table[id] else {
			throw NymphError.noSuchID(id)
		}
		let result: GuestExecResult = try await entry.control.exec(
			command,
			timeout: timeout,
			standardInput: standardInput,
			workingDirectory: workingDirectory,
			environment: environment
		)
		return ExecuteResult(standardOutput: result.standardOutput, standardError: result.standardError, exit: result.exitCode)
	}

	/// 列出 session（依 createdAt 穩定排序）。`all=false` 濾掉已 stopped 未回收者。
	public func list(all: Bool) async -> ListResult {
		var summaries: [SessionSummary] = []
		for entry in table.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
			let state: SessionState = await entry.control.currentState()
			guard all || state != .stopped else {
				continue
			}
			let ip: String? = await entry.control.currentIP() ?? entry.lastIP
			summaries.append(summary(for: entry, state: state, ip: ip))
		}
		return ListResult(sessions: summaries)
	}

	/// 查單一 session 狀態。no-such-id 擲錯。
	public func status(id: String) async throws -> StatusResult {
		guard let entry = table[id] else {
			throw NymphError.noSuchID(id)
		}
		let state: SessionState = await entry.control.currentState()
		let ip: String? = await entry.control.currentIP() ?? entry.lastIP
		return StatusResult(summary: summary(for: entry, state: state, ip: ip), stopReason: entry.stopReason)
	}

	/// 停 VM + 刪 clone + 移出 table。`force=true` → forceStop；`false` → 優雅停機。已
	/// stopped 未回收者 destroy 亦正常（只刪 clone）。no-such-id 擲錯。
	public func destroy(id: String, force: Bool) async throws -> DestroyResult {
		guard let entry = table[id] else {
			throw NymphError.noSuchID(id)
		}
		if force {
			try? await entry.control.forceStop()
		} else {
			try? await entry.control.gracefulStop(within: gracePeriod)
		}
		try? entry.control.destroyClone()
		cloneRegistry?.remove(entry.clonePath)
		table[id] = nil
		return DestroyResult(id: id, destroyed: true)
	}

	/// daemon 關閉收束（SIGTERM / SIGINT）：對每個 session forceStop + 刪 clone（設計
	/// §4.3；ephemeral 可拋、硬停是預設收法）。清空 table 與登記檔。
	public func drain() async {
		for entry in table.values {
			try? await entry.control.forceStop()
			try? entry.control.destroyClone()
			cloneRegistry?.remove(entry.clonePath)
		}
		table.removeAll()
	}

	/// 目前 session 數（測試 / 監看用）。
	public var count: Int {
		table.count
	}

	// MARK: Private

	/// 一筆 session 的記憶體狀態（設計 §4.1 SessionEntry；`clonePath` 為 host 路徑、僅
	/// daemon 內部持有、不出對外回傳）。
	private struct Entry {

		/// opaque handle（= table key、summary 回填用）。
		let id: String

		/// VM 控制面。
		let control: any GuestControl

		/// golden 別名（回傳用）。
		let goldenAlias: String

		/// clone host 路徑（内部）。
		let clonePath: URL

		/// vCPU 數。
		let cpus: Int

		/// 記憶體（GiB）。
		let memoryGiB: Int

		/// 建立時間（uptime 基準）。
		let createdAt: Date

		/// 最近一次解出的 IP 快取（currentIP 解不到時的退回值）。
		var lastIP: String?

		/// 停止原因（destroy force 記 `forced`；guest / error 需觀察 stop、屬後續切片）。
		var stopReason: String?
	}

	/// kind → 該種 guest 的引擎；查無即擲 ``NymphError/engineUnavailable(_:)``。
	private let engines: [GuestKind: any GuestEngine]

	/// 併發上限。
	private let maxSessions: Int

	/// 優雅停機上限。
	private let gracePeriod: Duration

	/// 孤兒回收登記。
	private let cloneRegistry: CloneRegistry?

	/// 時間源。
	private let clock: @Sendable () -> Date

	/// handle 產生器。
	private let makeHandle: @Sendable () -> String

	/// id -> Entry 的 session table。
	private var table: [String: Entry] = [:]

	/// 鑄造未撞號的 handle（碰撞極罕見、迴圈重取確保唯一）。
	private func mintHandle() -> String {
		var id: String = makeHandle()
		while table[id] != nil {
			id = makeHandle()
		}
		return id
	}

	/// 從 entry + 現時 state / ip 組對外摘要。
	private func summary(for entry: Entry, state: SessionState, ip: String?) -> SessionSummary {
		SessionSummary(
			id: entry.id,
			state: state,
			ip: ip,
			golden: entry.goldenAlias,
			cpus: entry.cpus,
			memoryGiB: entry.memoryGiB,
			uptimeSeconds: max(0, Int(clock().timeIntervalSince(entry.createdAt)))
		)
	}
}

/// socket 面把 ``NymphRequest`` 打進 store：分派到對應方法、``NymphError`` / ``ToolError``
/// 於此收斂成 ``NymphResponse/toolError(_:)``（tool-error envelope 不擲出連線層）。
extension SessionStore: RequestDispatching {

	public func handle(_ request: NymphRequest) async -> NymphResponse {
		do {
			switch request {
			case let .spawn(params):
				return .spawn(try await spawn(
					golden: params.golden,
					kind: params.kind,
					cpus: params.cpus,
					memoryGiB: params.memoryGiB,
					wait: params.wait,
					readinessTimeout: .seconds(params.readinessTimeoutSeconds)
				))

			case let .execute(params):
				return .execute(try await execute(
					id: params.id,
					command: params.command,
					timeout: params.timeoutSeconds.map { .seconds($0) },
					standardInput: params.standardInput,
					workingDirectory: params.workingDirectory,
					environment: params.environment
				))

			case let .list(params):
				return .list(await list(all: params.all))

			case let .status(params):
				return .status(try await status(id: params.id))

			case let .destroy(params):
				return .destroy(try await destroy(id: params.id, force: params.force))
			}
		} catch let error as NymphError {
			return .toolError(ToolError(error))
		} catch let error as ToolError {
			return .toolError(error)
		} catch {
			return .toolError(ToolError(.internalFailure(String(describing: error))))
		}
	}
}
