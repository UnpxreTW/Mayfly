//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// 與 MacGuest 同理由整檔 arch gate：session 建構觸碰 VZMac*（x86_64 無符號）。
#if arch(arm64)

/// 三面向外殼（app / CLI / MCP）共用的 guest 執行編排：bundle → boot → console 接
/// ``ReadinessGate`` → 解 IP → 長駐 → 停。編排單一正本在此，外殼只做 I/O 轉接
/// ——CLI 印 `READY ip=`、MCP 回 structured 結果、app 綁 UI，都消費同一個 session。
///
/// VM 活在 session 實例裡（``MacGuest`` 隨行程生滅）；instance-based、天然支援多
/// session（MCP server 的 named session table）。VZ 觸碰延後到 ``start()``——init
/// 只解 metadata、純 Foundation，佈局錯誤在建 session 時就擋下且可紙上測。
///
/// 只收 ``EphemeralBundle``：開機會寫 bundle（disk / NVRAM），golden 必須保持
/// pristine——ephemeral 優先是產品命題、clone 近乎免費（CoW），session 層以型別
/// 強制這條紀律。與 ``MacGuest`` 同為**一次性生命週期**：停止後不重啟、start 失敗
/// 即棄，要再跑另 clone 一份。
public actor MacGuestSession {

	// MARK: Public

	/// session 生命週期狀態（單向推進：idle → booting → ready → stopped；任何時點
	/// 都可能直接跳 stopped）。停止**原因**不入狀態——`MacGuestStopReason` 帶 error、
	/// 非 Equatable，單一真相是 ``waitUntilStopped()`` 的回傳值。
	public enum State: Sendable, Equatable {

		case idle

		case booting

		case ready(ip: String?)

		case stopped
	}

	/// 被駕馭的可拋 bundle。
	public nonisolated let bundle: EphemeralBundle

	/// 目前狀態快照（MCP status / app 綁定用；等待語義走 ``waitUntilReady()`` /
	/// ``waitUntilStopped()``）。
	public private(set) var state: State = .idle

	/// 建 guest、開機，並啟動 readiness 與停機兩路觀察。一次性：重呼（含首次失敗
	/// 後）擲 ``MacGuestSessionError/alreadyStarted``。
	public func start() async throws {
		guard !started else { throw MacGuestSessionError.alreadyStarted }
		started = true
		let spec: MacGuestSpec = MacGuestBundleLayout.spec(
			for: bundle.bundle,
			metadata: metadata,
			cpuCount: cpuCount,
			memoryBytes: memoryBytes,
			display: display
		)
		let consoleInput: Pipe = .init()
		let consoleOutput: Pipe = .init()
		let guest: MacGuest = try .init(
			spec: spec,
			console: .init(
				input: consoleInput.fileHandleForReading,
				output: consoleOutput.fileHandleForWriting
			)
		)
		// 在 await 前賦值：開機 suspension 期間 forceStop 仍可達（actor reentrancy）。
		self.consoleInput = consoleInput
		self.consoleOutput = consoleOutput
		self.guest = guest
		do {
			try await guest.start()
		} catch {
			// start 失敗即棄：回滾引用，讓之後的 waitUntilStopped / forceStop 一致
			// 擲 notStarted——否則 waitUntilStopped 會對一台從未跑起來的 VM 永久等。
			self.guest = nil
			self.consoleInput = nil
			self.consoleOutput = nil
			throw error
		}
		state = .booting
		observeReadiness(consoleReader: ConsoleReader(handle: consoleOutput.fileHandleForReading))
		observeStop(of: guest)
	}

	/// 等 readiness 收斂：回解出的 guest IP；gate 逾時無 IP 回 nil（best-effort）、
	/// guest 提早停止亦回 nil。未 start 擲 ``MacGuestSessionError/notStarted``。
	///
	/// 已被 ``promoteIfReady()`` 升成 `.ready` 時直接回報該 IP、不再空等一輪。
	public func waitUntilReady() async throws -> String? {
		guard let readinessTask else { throw MacGuestSessionError.notStarted }
		if case let .ready(ip) = state {
			return ip
		}
		return await readinessTask.value
	}

	/// 現查一次 host lease，解得出 IP 就把狀態自 `.booting` 升成 `.ready`（冪等、只從
	/// `.booting` 升）。回傳是否已處於 `.ready`。
	///
	/// gate 逾時（``ReadinessGate`` 兩路皆未解出 IP）時狀態刻意停在 `.booting`，此後的
	/// 收斂就靠本方法——呼叫端在查狀態或要 exec 時各補探一次，收斂不依賴當初有沒有等。
	/// 開機慢於 readinessTimeout 的 guest 因此仍會晚升、不會永停 `.booting`。
	///
	/// 證據取 lease 而非額外的 guest 內探測：macOS guest 的控制通道是 SSH、必須先有 IP，
	/// 解不出 IP 的 session 對呼叫端就是不可用，`.booting` 是如實回報；而 lease 是 host
	/// 本機檔案的一次讀取、有界且不觸網，不會把「查狀態」變成一次可能懸掛的遠端呼叫。
	@discardableResult
	public func promoteIfReady() -> Bool {
		if case .ready = state {
			return true
		}
		guard state == .booting, let ip = MacGuestLease.currentIP(macAddress: metadata.macAddress) else { return false }
		state = .ready(ip: ip)
		return true
	}

	/// 等 guest 停止、回停止原因（單一真相；語義同 ``MacGuest/waitUntilStopped()``）。
	public func waitUntilStopped() async throws -> MacGuestStopReason {
		guard let guest else { throw MacGuestSessionError.notStarted }
		return try await guest.waitUntilStopped()
	}

	/// 等 guest 自行停止、逾時 fallback 硬停（語義同 ``MacGuest/ensureStopped(within:)``；
	/// guest 內關機仍由呼叫端驅動、例如 SSH `sudo shutdown -h now`）。
	public func ensureStopped(within gracePeriod: Duration) async throws -> MacGuestStopReason {
		guard let guest else { throw MacGuestSessionError.notStarted }
		return try await guest.ensureStopped(within: gracePeriod)
	}

	/// host 硬停（destructive；ephemeral 複本本就可拋，這是 CI cleanup 的預設收法）。
	public func forceStop() async throws {
		guard let guest else { throw MacGuestSessionError.notStarted }
		try await guest.forceStop()
	}

	/// - Parameters:
	///   - bundle: 要開的可拋複本（``MacGuestCloner/clone(_:to:)`` 的產物）。
	///   - cpuCount: 要求的 vCPU 數，超出 host 上限由引擎收斂（見 ``MacGuestSpec``）。
	///   - memoryBytes: 要求的記憶體，同上收斂。
	///   - display: 顯示器設定；macOS guest 一定掛圖形裝置、headless 只是不開視窗。
	///   - readinessTimeout: readiness 兩路競速的整體上限。冷開機到 DHCP/marker 需
	///     數十秒起跳，預設 180s——``ReadinessGate`` 自身預設（10s）是為單元測試
	///     節奏設的、不適合真開機。
	public init(
		bundle: EphemeralBundle,
		cpuCount: Int = 4,
		memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024,
		display: MacGuestSpec.Display = .init(),
		readinessTimeout: Duration = .seconds(180)
	) throws {
		self.bundle = bundle
		self.metadata = try JSONDecoder().decode(
			BundleMetadata.self,
			from: Data(contentsOf: MacGuestBundleLayout.metadata(in: bundle.bundle))
		)
		self.cpuCount = cpuCount
		self.memoryBytes = memoryBytes
		self.display = display
		self.readinessTimeout = readinessTimeout
	}

	// MARK: Private

	/// FileHandle 的 Sendable 封套：console 讀端只在 tee Task 內觸碰（單一讀者），
	/// 跨界僅為把讀端交進該 Task——與 ``MacGuest`` 的 queue 合約同精神。
	private struct ConsoleReader: @unchecked Sendable {

		let handle: FileHandle
	}

	/// readinessTimeout 的飽和毫秒轉換：溢位夾到 `Int.max`（形同無界）、負值夾到 0
	/// （gate 立即逾時）——不讓極端輸入變成算術 trap。
	private var readinessTimeoutMilliseconds: Int {
		let components = readinessTimeout.components
		let (base, overflow) = components.seconds.multipliedReportingOverflow(by: 1000)
		if overflow {
			return components.seconds > 0 ? Int.max : 0
		}
		let total = base + components.attoseconds / 1_000_000_000_000_000
		return Int(min(Int64(Int.max), max(0, total)))
	}

	/// clone 的建立資訊（MAC 供 lease 反查）。
	private let metadata: BundleMetadata

	/// 要求的 vCPU 數。
	private let cpuCount: Int

	/// 要求的記憶體（bytes）。
	private let memoryBytes: UInt64

	/// 顯示器設定。
	private let display: MacGuestSpec.Display

	/// readiness 兩路競速的整體上限。
	private let readinessTimeout: Duration

	/// start 是否呼叫過（含失敗）；一次性生命週期的閂。
	private var started = false

	/// 被駕馭的 guest（start 成功前為 nil）。
	private var guest: MacGuest?

	/// host → guest 輸入管（guest 存活期間必須持有、避免 handle 被回收）。
	private var consoleInput: Pipe?

	/// guest → host console 輸出管（同上持有）。
	private var consoleOutput: Pipe?

	/// console 行讀取 tee（guest 輸出 → AsyncStream）。
	private var consoleTask: Task<Void, Never>?

	/// readiness 觀察：gate 收斂後更新狀態、值＝解出的 IP。
	private var readinessTask: Task<String?, Never>?

	/// 停機觀察：guest 停止後更新狀態、收掉 console / readiness 兩個 task。
	private var stopTask: Task<Void, Never>?

	/// 把 console 輸出橋成行流、餵 ``ReadinessGate`` 兩路競速，收斂時標記 ready。
	private func observeReadiness(consoleReader: ConsoleReader) {
		let (lines, linesContinuation) = AsyncStream.makeStream(of: String.self)
		consoleTask = Task {
			do {
				for try await line in consoleReader.handle.bytes.lines {
					linesContinuation.yield(line)
				}
			} catch {}
			linesContinuation.finish()
		}
		let gate: ReadinessGate = .init(
			macAddress: metadata.macAddress,
			leaseResolveTimeoutMilliseconds: readinessTimeoutMilliseconds
		)
		readinessTask = Task {
			var resolved: String?
			for await readiness in gate.readiness(consoleLines: lines) {
				if case let .provisioningReady(ip) = readiness {
					resolved = ip
				}
			}
			// Task 閉包繼承 actor 隔離（非 detached）——markReady 是同 actor 同步呼叫。
			self.markReady(ip: resolved)
			return resolved
		}
	}

	/// 停機觀察：`waitUntilStopped` 收斂（含 forceStop 的收斂）後標記 stopped。
	private func observeStop(of guest: MacGuest) {
		stopTask = Task {
			_ = try? await guest.waitUntilStopped()
			self.markStopped()
		}
	}

	/// booting → ready 的單向轉移；已 stopped 則不回退。
	///
	/// 無 IP 不升：``ReadinessGate`` 只在兩路競速都沒解出 IP（＝整體逾時）時才送
	/// `provisioningReady(ip: nil)`，那不是收斂、是放棄等待，升成 `.ready` 會讓呼叫端拿到
	/// 一個連不上的 session。逾時後停在 `.booting`、之後由 ``promoteIfReady()`` 晚升。
	private func markReady(ip: String?) {
		guard state == .booting, let ip else { return }
		state = .ready(ip: ip)
	}

	/// 任何時點 → stopped；停止後 console / readiness 兩路觀察一併收掉。
	///
	/// tee 的收法必須是**關 pipe、不是 cancel**：`FileHandle.bytes.lines` 只在讀與讀
	/// 之間觀察取消，卡在空 pipe 上的讀不會被 cancel 打斷；而 write 端被 session 與
	/// VZ attachment 雙持有、不顯式關就永無 EOF——tee task 與兩對 fd 會隨 session
	/// 存活期洩漏（MCP 長駐行程的 session table 逐 job 累積）。guest 已停、無寫者，
	/// 關閉安全。
	private func markStopped() {
		state = .stopped
		readinessTask?.cancel()
		consoleTask?.cancel()
		try? consoleOutput?.fileHandleForWriting.close()
		try? consoleInput?.fileHandleForReading.close()
		consoleInput = nil
		consoleOutput = nil
	}
}

#endif
