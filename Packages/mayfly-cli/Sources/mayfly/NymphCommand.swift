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

	func run() async throws {
#if arch(arm64)
		// 對端斷線時 socket write 收 EPIPE、不讓 SIGPIPE 打死常駐 daemon。
		signal(SIGPIPE, SIG_IGN)
		let stateDirectory: URL = NymphPaths.stateDirectory()
		try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
		let hostKey: NymphHostKey = try await NymphHostKey.loadOrGenerate(in: stateDirectory)
		let registry: CloneRegistry = .init(fileURL: NymphPaths.cloneRegistryURL())
		let reclaimed: [URL] = registry.sweepOrphans()
		if !reclaimed.isEmpty {
			FileHandle.standardError.write(Data("nymph: reclaimed \(reclaimed.count) orphan clone(s)\n".utf8))
		}
		let macEngine: RealGuestEngine = .init(hostKey: hostKey, resolver: .fromEnvironment())
		// 預設不接網路（network: nil）：容器沒有對外連線、`currentIP()` 恆回 nil，readiness
		// 改由容器內探測驅動（見 `LinuxGuestControl`）；接上容器網路另行處理。
		let linuxEngine: LinuxGuestEngine = .init()
		let store: SessionStore = .init(
			engines: [.mac: macEngine, .linux: linuxEngine],
			maxSessions: maxSessions,
			cloneRegistry: registry
		)
		let socketURL: URL = NymphPaths.socketURL()
		let server: NymphServer = .init(socketPath: socketURL, dispatcher: store)
		try server.start()
		FileHandle.standardOutput.write(Data("nymph: listening on \(socketURL.path)\n".utf8))
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
