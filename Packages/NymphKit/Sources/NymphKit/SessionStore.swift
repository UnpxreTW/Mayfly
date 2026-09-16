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
	///   - maxSessions: **macOS** guest 的併發上限（admission；設計 §10.4 的最小落地——先做
	///     VM 數上限，記憶體 / CPU 總量准入留後續）。
	///   - maxLinuxSessions: **Linux** guest 的併發上限。兩種 guest 各數各的：macOS 每 host
	///     受 Virtualization.framework 限制（同時最多兩台）、Linux 容器沒有這條限制，合在一個
	///     計數裡會讓 Linux 吃掉 macOS 的席位。兩個預設值都只是 daemon 這層的軟上限，實際值
	///     由部署端給。已 stopped 的 session 不佔席，並在下一次同種 spawn 的准入檢查裡就地回收
	///     （**目前只對 macOS 成立**——Linux 側的控制面只在 start 失敗與強制停止時翻成 stopped，
	///     容器自行 exit 不翻態，那條回收因此不會觸發；偵測容器自停屬 LinuxNodeKit 的後續工作）。
	///     還有人握著的 session（spawn 尚未回、execute 進行中）照樣佔席、也不被回收。
	///   - gracePeriod: `destroy force=false` 的優雅停機上限。
	///   - cloneRegistry: 孤兒回收登記（nil＝不登記、僅記憶體 table）。
	///   - logSink: session 操作紀錄的落點（nil＝關閉、零量測）。**開啟時每次操作多讀一次
	///     `clock`**（事件時間戳），依賴 clock 呼叫次數的測試須自行注入固定時鐘。
	///   - clock: 時間源（uptime 計算；測試注入固定值）。
	///   - makeHandle: opaque handle 產生器（測試注入確定序列）。
	public init(
		engines: [GuestKind: any GuestEngine],
		maxSessions: Int = 8,
		maxLinuxSessions: Int = 2,
		gracePeriod: Duration = .seconds(30),
		cloneRegistry: CloneRegistry? = nil,
		logSink: SessionLogSink? = nil,
		clock: @escaping @Sendable () -> Date = { Date() },
		makeHandle: @escaping @Sendable () -> String = { SessionStore.randomHandle() }
	) {
		self.engines = engines
		self.maxSessions = maxSessions
		self.maxLinuxSessions = maxLinuxSessions
		self.gracePeriod = gracePeriod
		self.cloneRegistry = cloneRegistry
		self.logSink = logSink
		self.clock = clock
		self.makeHandle = makeHandle
	}

	/// 只掛 macOS 引擎的便利建構（等同 `engines: [.mac: engine]`）——`os: linux` 的請求
	/// 於此形下擲 ``NymphError/engineUnavailable(_:)``。
	public init(
		engine: any GuestEngine,
		maxSessions: Int = 8,
		gracePeriod: Duration = .seconds(30),
		cloneRegistry: CloneRegistry? = nil,
		logSink: SessionLogSink? = nil,
		clock: @escaping @Sendable () -> Date = { Date() },
		makeHandle: @escaping @Sendable () -> String = { SessionStore.randomHandle() }
	) {
		self.init(
			engines: [.mac: engine],
			maxSessions: maxSessions,
			gracePeriod: gracePeriod,
			cloneRegistry: cloneRegistry,
			logSink: logSink,
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

	/// clone + boot + 等 readiness 收斂：`wait=true`（預設）阻塞到 READY、逾時無 IP **降級回
	/// booting 不自殺**（VM 續跑、client 之後以 status 輪詢）；`wait=false` 即回 booting。
	///
	/// 引擎由 `kind` 選定（線協議 `os` 欄、非別名字面推斷）；該 kind 未註冊引擎時擲
	/// ``NymphError/engineUnavailable(_:)``，不代打、不猜。必填語義在線協議層
	/// （``SpawnParams/os`` 缺欄即解碼失敗）；此處的 `.mac` 預設是行程內呼叫端的便利，
	/// 與只掛 macOS 引擎的便利建構同款。
	public func spawn(
		golden: String,
		kind: GuestKind = .mac,
		cpus: Int,
		memoryGiB: Int,
		wait: Bool,
		readinessTimeout: Duration
	) async throws -> SpawnResult {
		try await logging(.spawn, golden: golden, kind: kind) { trace in
			guard let engine: any GuestEngine = engines[kind] else { throw NymphError.engineUnavailable(kind) }
			let ceiling: Int = limit(for: kind)
			// 先佔位、再計數，且把自己那一席一併算進去（於是邊界是 `>` 而不是 `<`）。計數本身含
			// await——回收那一趟要向控制面查狀態——actor 期間可重入，「數完才佔位」會讓兩個同時
			// 進來的請求各自數到同一個較小值而雙雙放行。反過來先佔位，後到的那個必定看得見前一個
			// 的席位：席位是在任何 await 之前掛上的，而計數的第一趟（走訪佔位席）整趟沒有等待點。
			// 席位撐到整趟 spawn 回傳才放，另一件事也一併成立：start / waitUntilReady 期間 guest
			// 若自行停機，別人的准入回收不會把這條當成殘留收走——那會讓呼叫端拿到一個當場即
			// noSuchID 的 handle、紀錄面的「訖」還排在「起」之前。
			let id: String = mintHandle()
			retainInflight(id, kind: kind)
			defer { releaseInflight(id) }
			guard await runningCountReclaimingStopped(of: kind) <= ceiling else {
				throw NymphError.admissionDenied(limit: ceiling)
			}
			let provisioned: ProvisionedGuest = try await engine.provision(
				golden: golden,
				cpus: cpus,
				memoryGiB: memoryGiB,
				readinessTimeout: readinessTimeout
			)
			trace?.mark(.provision)
			trace?.sessionID = id
			cloneRegistry?.add(provisioned.clonePath)
			table[id] = Entry(
				id: id,
				kind: kind,
				control: provisioned.control,
				goldenAlias: provisioned.goldenAlias,
				clonePath: provisioned.clonePath,
				cpus: cpus,
				memoryGiB: memoryGiB,
				createdAt: clock()
			)
			do {
				try await provisioned.control.start()
				trace?.mark(.start)
			} catch {
				try? provisioned.control.destroyClone()
				cloneRegistry?.remove(provisioned.clonePath)
				table[id] = nil
				throw NymphError.internalFailure("spawn start failed: \(error)")
			}
			guard wait else {
				trace?.state = .booting
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
			trace?.mark(.ready)
			trace?.state = state
			table[id]?.lastIP = ip
			return SpawnResult(id: id, state: state, ip: ip)
		}
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
		try await logging(.execute, sessionID: id, command: command.first) { trace in
			guard let entry: Entry = table[id] else {
				throw NymphError.noSuchID(id)
			}
			// exec 這一段可以很長（呼叫端給的 timeout 可達小時級）；期間 guest 自行停機的話，併發
			// 的准入回收會把 clone 刪在 exec 進行中。整段掛在佔位席上，回收那一趟就跳過它。
			retainInflight(id, kind: entry.kind)
			defer { releaseInflight(id) }
			let result: GuestExecResult = try await entry.control.exec(
				command,
				timeout: timeout,
				standardInput: standardInput,
				workingDirectory: workingDirectory,
				environment: environment
			)
			trace?.mark(.exec)
			trace?.exitCode = result.exitCode
			return ExecuteResult(standardOutput: result.standardOutput, standardError: result.standardError, exit: result.exitCode)
		}
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
		try await logging(.status, sessionID: id) { trace in
			guard let entry: Entry = table[id] else {
				throw NymphError.noSuchID(id)
			}
			let state: SessionState = await entry.control.currentState()
			let ip: String? = await entry.control.currentIP() ?? entry.lastIP
			trace?.state = state
			return StatusResult(summary: summary(for: entry, state: state, ip: ip), stopReason: entry.stopReason)
		}
	}

	/// 停 VM + 刪 clone + 移出 table。`force=true` → forceStop；`false` → 優雅停機。已
	/// stopped 未回收者 destroy 亦正常（只刪 clone）。no-such-id 擲錯。
	public func destroy(id: String, force: Bool) async throws -> DestroyResult {
		try await logging(.destroy, sessionID: id, force: force) { trace in
			guard let entry: Entry = table[id] else {
				throw NymphError.noSuchID(id)
			}
			destroying.insert(id)
			defer { destroying.remove(id) }
			if force {
				try? await entry.control.forceStop()
			} else {
				try? await entry.control.gracefulStop(within: gracePeriod)
			}
			trace?.mark(.stop)
			try? entry.control.destroyClone()
			cloneRegistry?.remove(entry.clonePath)
			table[id] = nil
			return DestroyResult(id: id, destroyed: true)
		}
	}

	/// daemon 關閉收束（SIGTERM / SIGINT）：對每個 session forceStop + 刪 clone（設計
	/// §4.3；ephemeral 可拋、硬停是預設收法）。清空 table 與登記檔。
	///
	/// 每個被收掉的 session 各記一筆 `drain` 事件——關機這條路上 session 一樣走到了終點，
	/// 不記的話紀錄面只看得到「起」、看不到「訖」。收束本身不擲錯（單一 session 停不下來或
	/// clone 刪不掉都不該擋住其餘 session），事件因此恆為 `ok`。
	public func drain() async {
		destroying.formUnion(table.keys)
		defer { destroying.removeAll() }
		for entry in table.values {
			_ = try? await logging(.drain, sessionID: entry.id, force: true) { trace in
				try? await entry.control.forceStop()
				trace?.mark(.stop)
				try? entry.control.destroyClone()
				cloneRegistry?.remove(entry.clonePath)
			}
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

		/// 這台 guest 的種類（admission 逐種計數用；對外摘要不露）。
		internal let kind: GuestKind

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

	/// 一席佔位：誰的種類、還有幾個人握著。
	private struct InflightSeat {

		/// guest 種類（准入逐種計數用）。
		internal let kind: GuestKind

		/// 目前握著這條 session 的操作數（spawn 一趟算一個、每個 execute 各算一個）。
		internal var holders: Int
	}

	/// kind → 該種 guest 的引擎；查無即擲 ``NymphError/engineUnavailable(_:)``。
	private let engines: [GuestKind: any GuestEngine]

	/// macOS guest 的併發上限。
	private let maxSessions: Int

	/// Linux guest 的併發上限。
	private let maxLinuxSessions: Int

	/// 優雅停機上限。
	private let gracePeriod: Duration

	/// 孤兒回收登記。
	private let cloneRegistry: CloneRegistry?

	/// session 操作紀錄的落點；nil＝關閉。
	private let logSink: SessionLogSink?

	/// 時間源。
	private let clock: @Sendable () -> Date

	/// handle 產生器。
	private let makeHandle: @Sendable () -> String

	/// id -> Entry 的 session table。
	private var table: [String: Entry] = [:]

	/// 正在被 destroy／drain 收走的 session id。
	///
	/// 停機那一步有 await（Linux 的 stop、macOS 的 grace 最長 30 秒），期間 actor 可重入：控制面
	/// 多半已先翻成 stopped，併發 spawn 的准入回收於是會把它當成沒人收的殘留、就地刪掉同一顆
	/// clone，紀錄面也多出一筆「訖」。進停機之前先把 id 記在這裡、回收那一趟跳過它，等停機收斂
	/// 後由 destroy 自己收完再移除。
	private var destroying: Set<String> = []

	/// 手上還握著某條 session 的操作（spawn 整趟、execute 整段 exec），id → 佔位席。
	///
	/// 這些 id 的 table 條目可能還沒寫進去（spawn 佔位在 provision 之前），或狀態已經翻成
	/// stopped（guest 自行關機）卻還有人在用它的 clone。回收那一趟對集合內的 id 一律跳過、
	/// 且照算一席——資源正握在手上。
	///
	/// 計數而非旗標：同一條 session 可以同時有多個 execute，用 Set 的話先收工的那個會把還在跑
	/// 的那個的旗標一併清掉。
	private var inflight: [String: InflightSeat] = [:]

	/// 掛住一席：同一 id 再掛就加一。
	/// - Parameters:
	///   - id: session handle。
	///   - kind: guest 種類（table 條目還不存在時，准入靠這欄知道該算進哪一種的計數）。
	private func retainInflight(_ id: String, kind: GuestKind) {
		if var seat: InflightSeat = inflight[id] {
			seat.holders += 1
			inflight[id] = seat
		} else {
			inflight[id] = InflightSeat(kind: kind, holders: 1)
		}
	}

	/// 放掉一席；最後一個放手的把條目移除。
	/// - Parameter id: session handle。
	private func releaseInflight(_ id: String) {
		guard var seat: InflightSeat = inflight[id] else { return }
		seat.holders -= 1
		inflight[id] = seat.holders > 0 ? seat : nil
	}

	/// 鑄造未撞號的 handle（碰撞極罕見、迴圈重取確保唯一）。
	///
	/// 佔位席一併避開——spawn 在條目寫進 table 之前就先鑄號，只看 table 會把還在 provision 的
	/// 那顆號碼再發一次。
	private func mintHandle() -> String {
		var id: String = makeHandle()
		while table[id] != nil || inflight[id] != nil {
			id = makeHandle()
		}
		return id
	}

	/// 該種 guest 的席位上限。
	///
	/// 逐 case 列而不給預設分支——之後新增 ``GuestKind`` 時，編譯器會在這裡把「新種 guest 的
	/// 上限沒人定」擋下來，而不是讓它悄悄套用某一種既有上限。
	/// - Parameter kind: guest 種類。
	/// - Returns: 同時可在跑的上限。
	private func limit(for kind: GuestKind) -> Int {
		switch kind {
		case .mac:
			maxSessions

		case .linux:
			maxLinuxSessions
		}
	}

	/// 該種 guest 目前**在跑**的數量；已 stopped 的殘留在同一趟就地回收。
	///
	/// 不計 stopped——席位佔的是真正跑著的 guest，把它們算進去會讓還沒 destroy 的殘留把後面的
	/// spawn 擋在門外。但「只是不計」會開另一個洞：不呼叫 destroy 的呼叫端（斷線、guest 跑完
	/// 自行關機）會讓 table 條目與 clone 無界累積，而孤兒回收只在 daemon 啟動時跑一次、執行期
	/// 沒有任何回收者，磁碟遲早被 clone 吃光。因此這裡逐條收掉：刪 clone、移出登記與 table，
	/// 各記一筆 `reap`。
	///
	/// 狀態只查一次、回收與計數同一趟——Linux 側的 `currentState()` 會觸發一次 guest 內探測
	/// （單次逾時 5 秒），分兩趟查等於把 spawn 的等待時間翻倍。
	///
	/// 已經有人在收的（``destroying``）或還有人握著的（``inflight``）不碰，且仍算它一席——
	/// 停機尚未收斂、或 clone 正被 spawn／exec 用著，資源都還在手上。尚未寫進 table 的佔位席
	/// （spawn 在 provision 之前就佔號）另外數，否則那台開到一半的 guest 不佔席。
	///
	/// - Important: 這條回收目前只對 macOS 生效——Linux 的控制面只在 start 失敗與強制停止時
	///   翻成 stopped，容器自行 exit 不翻態、於是永遠不落進這一趟；那是 LinuxNodeKit 的後續
	///   工作，本層無從得知。
	/// - Important: 呼叫端自己那一席也在內——spawn 先佔位才來數，於是回傳值含它自己，准入的
	///   邊界因此是「超過上限才擋」。走訪佔位席的那一趟（本函式的第一個迴圈）整趟沒有 await，
	///   後到的請求必定看得見先到者的席位，兩個併發的 spawn 不會各自數到同一個較小值。
	/// - Note: 「還有人握著就仍算它一席」有一道窄窗不成立：查狀態那一步讓出之後才掛上的
	///   ``inflight``，會在回來的重看那一關落進不收也不計的分支——該趟少算一席，下一趟就補回來。
	/// - Parameter kind: guest 種類。
	/// - Returns: 回收之後，該種仍在跑的 session 數（含呼叫端自己已掛上的佔位席）。
	private func runningCountReclaimingStopped(of kind: GuestKind) async -> Int {
		var count: Int = 0
		for (id, seat) in inflight where seat.kind == kind && table[id] == nil {
			count += 1
		}
		for id in table.compactMap({ $0.value.kind == kind ? $0.key : nil }) {
			guard let entry: Entry = table[id] else { continue }
			guard
				!destroying.contains(id),
				inflight[id] == nil
			else {
				count += 1
				continue
			}
			guard await entry.control.currentState() == .stopped else {
				count += 1
				continue
			}
			// 查狀態這一步有 await：期間可能有 destroy 接手了同一條、或有 execute 掛了上去，回來
			// 要重看一次是不是同一顆、還有沒有人握著，免得對同一顆 clone 動第二次手。
			guard
				table[id]?.clonePath == entry.clonePath,
				!destroying.contains(id),
				inflight[id] == nil
			else { continue }
			// 這一趟是准入的順手清理、不是呼叫端要的操作：收不掉的殘留不該把 spawn 擋在門外，
			// 也不該擋住同一趟裡其餘殘留的回收，故兩處失敗都只當「沒收成」。
			// 外層：body 自己不擲，唯一的擲錯來源是發事件那一步。
			// 內層：clone 刪不掉就留下一個孤兒目錄（占磁碟、不影響正確性），與 destroy／drain
			// 同一種處置；擲錯反而會讓這條殘留永遠留在 table 裡佔著席位。
			_ = try? await logging(.reap, sessionID: id, kind: kind) { _ in
				try? entry.control.destroyClone()
				cloneRegistry?.remove(entry.clonePath)
				table[id] = nil
			}
		}
		return count
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

	/// 包住一次操作：sink 關（nil）→ 原樣跑 `body`，不建 trace、不讀任何時鐘；開 → 建 trace、
	/// 跑完（含擲錯）發一筆事件，再原樣回傳或重擲。`body` 收到的 trace 在關閉時是 nil，四個
	/// 方法內的 `trace?.` 因此整條短路。
	private func logging<Value>(
		_ operation: SessionLogEvent.Operation,
		sessionID: String? = nil,
		golden: String? = nil,
		kind: GuestKind? = nil,
		command: String? = nil,
		force: Bool? = nil,
		_ body: (SessionLogTrace?) async throws -> Value
	) async throws -> Value {
		guard let logSink else { return try await body(nil) }
		let trace: SessionLogTrace = .init(
			operation: operation,
			sessionID: sessionID,
			golden: golden,
			kind: kind,
			command: command,
			force: force
		)
		do {
			let value: Value = try await body(trace)
			logSink(trace.finish(timestamp: clock(), outcome: .ok))
			return value
		} catch {
			logSink(trace.finish(timestamp: clock(), outcome: .error(SessionStore.toolError(for: error))))
			throw error
		}
	}

	/// 錯誤 → 對外穩定碼：``NymphError`` 走 ``ToolError`` 既有的映射、``ToolError`` 原樣回、
	/// 其餘收斂成 `internal_error`。紀錄與 ``handle(_:)`` 共用這一套，兩處的碼不會漂開。
	private static func toolError(for error: any Error) -> ToolError {
		switch error {
		case let error as NymphError:
			ToolError(error)

		case let error as ToolError:
			error

		default:
			ToolError(.internalFailure(String(describing: error)))
		}
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
					kind: params.os,
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
		} catch {
			return .toolError(SessionStore.toolError(for: error))
		}
	}
}
