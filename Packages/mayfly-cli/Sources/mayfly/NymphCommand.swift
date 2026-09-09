//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Dispatch
import Foundation
import LinuxNodeKit
import MachineKit
import NymphKit

#if canImport(Darwin)
import Darwin
#endif

/// `mayfly nymph`：起常駐 daemon——loadOrGenerate 穩定身份鑰、掃孤兒 clone、開 Unix
/// socket、跑 `SessionStore`。真共享（設計決策②）：client 來去、session table 不隨單一
/// client 斷線收束。收 SIGTERM / SIGINT → drain（每 session forceStop + destroy clone）後退出。
///
/// 每種 guest 各掛一顆引擎：macOS 走 ``RealGuestEngine``、Linux 走 `LinuxGuestEngine`。
/// spawn 依請求帶的 `os` 欄挑引擎，沒掛引擎的種類回 `engine_unavailable`、不由別顆代打。
///
/// arm64 限定（引擎觸碰 Virtualization.framework）；非 Apple Silicon 比照 `run` 明確擋下。
struct NymphCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "nymph",
		abstract: "Run the long-lived nymph daemon (listens on a Unix domain socket)."
	)

	/// 併發 session 上限（admission）。
	@Option(name: .customLong("max-sessions"), help: "Maximum concurrent sessions (admission ceiling).")
	var maxSessions: Int = 8

	/// macOS guest 的 SSH 帳號——golden image 把 nymph 公鑰注進哪個帳號，這裡就填哪個。
	/// 預設 `runner`。readiness 走 host lease 解 IP、不經 SSH，所以帳號填錯的 session 照樣
	/// 升到 ready，失敗遞延到 execute 的公鑰認證被拒。
	@Option(
		name: .customLong("guest-username"),
		help: "SSH account inside macOS guests (must match the golden image)."
	)
	internal var guestUsername: String = "runner"

	/// 把每次 spawn／execute／status／destroy 的分段耗時寫成一行到 stderr，並在紀錄面補上
	/// session 起訖各一行。預設關；開了也只是多出診斷輸出、不改任何回應內容。
	@Flag(
		name: .customLong("log-sessions"),
		help: """
		Log one line per spawn/execute/status/destroy with phase timings to stderr, plus a log entry \
		when a session begins or ends.
		"""
	)
	internal var logSessions: Bool = false

	/// Linux 容器接哪一種網路（`vmnet`／`none`）。字面值在 `run()` 內驗，不對
	/// ``LinuxNetworkMode`` 補 `ExpressibleByArgument`——那是跨模組替別人的型別套別人的
	/// 協定，比照 `spawn` 的 `--os` 既有形。
	@Option(
		name: .customLong("linux-network"),
		help: "Network for Linux guests: vmnet (shared, outbound connectivity) or none."
	)
	internal var linuxNetwork: String = LinuxNetworkMode.vmnet.rawValue

	/// 紀錄門檻（`--log-level`；未給時看 `LOG_LEVEL`）。
	@OptionGroup
	internal var logging: LoggingOptions

	func run() async throws {
#if arch(arm64)
		guard let networkMode: LinuxNetworkMode = .init(rawValue: linuxNetwork) else {
			let expected: String = LinuxNetworkMode.allCases.map(\.rawValue).joined(separator: ", ")
			throw ValidationError("unknown --linux-network value \"\(linuxNetwork)\"; expected one of: \(expected).")
		}
		// 對端斷線時 socket write 收 EPIPE、不讓 SIGPIPE 打死常駐 daemon。
		signal(SIGPIPE, SIG_IGN)
		let stateDirectory: URL = NymphPaths.stateDirectory()
		try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
		let hostKey: NymphHostKey = try await NymphHostKey.loadOrGenerate(in: stateDirectory)
		let registry: CloneRegistry = .init(fileURL: NymphPaths.cloneRegistryURL())
		let reclaimed: [URL] = registry.sweepOrphans()
		if !reclaimed.isEmpty {
			CommandOutput.logger.info("reclaimed \(reclaimed.count) orphan clone(s)")
		}
		let macEngine: RealGuestEngine = .init(
			hostKey: hostKey,
			resolver: .fromEnvironment(),
			username: guestUsername
		)
		// 網路交給 provider 持有：整支 daemon 共用一顆、第一次 Linux spawn 才建。啟動期不建，
		// vmnet 開不起來時 macOS 路徑不受牵連（`--linux-network none` 則從頭就不接網路）。
		let networkProvider: LinuxNetworkProvider = .init(mode: networkMode)
		let linuxEngine: LinuxGuestEngine = .init(networkProvider: networkProvider)
		CommandOutput.logger.info("linux network: \(NymphCommand.startupDescription(for: networkMode))")
		let logSink: SessionLogSink? = logSessions ? NymphCommand.emit(sessionEvent:) : nil
		let store: SessionStore = .init(
			engines: [.mac: macEngine, .linux: linuxEngine],
			maxSessions: maxSessions,
			cloneRegistry: registry,
			logSink: logSink
		)
		let socketURL: URL = NymphPaths.socketURL()
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: store)
		try server.start()
		CommandOutput.logger.info("listening on \(socketURL.path)")
		// SIGTERM / SIGINT → drain + shutdown + exit；sources 綁在 run() frame（下方阻塞
		// 迴圈維持存活）。
		let sources: [any DispatchSourceSignal] = Self.installDrainHandlers(store: store, server: server)
		defer { sources.forEach { $0.cancel() } }
		while true {
			try await Task.sleep(for: .seconds(3600))
		}
#else
		throw ValidationError("mayfly nymph requires Apple Silicon.")
#endif
	}

#if arch(arm64)

	/// 啟動日誌那一行的網路描述。
	///
	/// vmnet 明寫「首次 session 才建」——這一行印出來時網路還不存在，寫成既成事實會讓讀日誌
	/// 的人把「daemon 起來了」當成「網路已經備妥」。
	/// - Parameter mode: 啟動參數解出來的模式。
	/// - Returns: 接在 `linux network: ` 後面的描述。
	private static func startupDescription(for mode: LinuxNetworkMode) -> String {
		switch mode {
		case .vmnet:
			"vmnet (mtu \(LinuxContainerNetwork.defaultMTU), created on first session)"

		case .disabled:
			"none"
		}
	}

	/// store 每次操作的落點：資料行照舊直寫 stderr，起訖兩種事件另在紀錄面留一行 `info`。
	///
	/// 兩條線刻意分開——資料行的欄序是對外的固定格式（`nymph: session ts=… op=… result=…`），
	/// 套上紀錄後端的時間戳與標籤前綴就多一個冗餘的時間欄、也不再是原本那個形狀；而只看紀錄
	/// 那一面的人需要知道 session 何時起、何時收，那句話帶著同一個 id、指回資料行。
	private static func emit(sessionEvent event: SessionLogEvent) {
		writeSessionEvent(toStandardError: event)
		guard let message: String = event.lifecycleMessage else { return }
		CommandOutput.logger.info("\(message)")
	}

	/// 資料行的寫出口：一事件一行、直接寫 handle，**不經 `Logger`**。
	///
	/// - Note: 走會擲錯的 `write(contentsOf:)` 並吞掉錯誤——stderr 接到已關閉的 pipe 時，
	///   非擲錯版會丟出無人接的例外、把常駐 daemon 整支帶走；而這條每次操作都會跑。
	private static func writeSessionEvent(toStandardError event: SessionLogEvent) {
		try? FileHandle.standardError.write(contentsOf: Data((event.description + "\n").utf8))
	}

	/// 掛 SIGTERM / SIGINT：先 SIG_IGN 停用預設終止、再以 `DispatchSource` 收訊號 → drain
	/// 全 session、關 socket、退出。回傳 sources 供呼叫端保活。
	private static func installDrainHandlers(store: SessionStore, server: NymphServer) -> [any DispatchSourceSignal] {
		signal(SIGTERM, SIG_IGN)
		signal(SIGINT, SIG_IGN)
		let drain: @Sendable () -> Void = {
			Task {
				await store.drain()
				server.shutdown()
				Foundation.exit(0)
			}
		}
		let terminate: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGTERM)
		terminate.setEventHandler(handler: drain)
		terminate.resume()
		let interrupt: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGINT)
		interrupt.setEventHandler(handler: drain)
		interrupt.resume()
		return [terminate, interrupt]
	}
#endif
}
