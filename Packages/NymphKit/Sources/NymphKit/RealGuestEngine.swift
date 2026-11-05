//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

// 引擎真機路徑觸碰 MacGuestSession（VZ、arm64 限定）與 MacGuestExec 的 session overload——整段
// arch gate。核心 SessionStore / 協議 / socket 皆 arch-neutral、以 fake 驅動可跨 arch 測；
// 只有這層真接引擎。非 arm64 由 `mayfly nymph` 命令層擋下（比照 RunCommand）。
#if arch(arm64)

/// ``GuestEngine`` 的真機實作：golden 別名 → `clonefile` 落地 → 建 `MacGuestSession`（未 start）
/// → 包成 ``RealGuestControl``。組合現有引擎正本（`MacGuestCloner` / `MacGuestSession` /
/// `MacGuestExec` / `MacGuestLease`），本層只做別名解析、clone 落點、身份鑰接線——不改引擎。
public struct RealGuestEngine: GuestEngine {

	// MARK: Public

	/// - Parameters:
	///   - hostKey: nymph 穩定身份鑰（`mayfly nymph` 首啟 loadOrGenerate）。
	///   - resolver: golden 別名解析 + clone 落點。
	///   - username: SSH 連入的 guest 帳號（golden 注入公鑰的那個），預設 `runner`。
	///   - cloner: CoW 複製器。
	public init(
		hostKey: NymphHostKey,
		resolver: GoldenResolver,
		username: String = "runner",
		cloner: MacGuestCloner = MacGuestCloner()
	) {
		self.hostKey = hostKey
		self.resolver = resolver
		self.username = username
		self.cloner = cloner
	}

	public func provision(
		golden: String,
		cpus: Int,
		memoryGiB: Int,
		readinessTimeout: Duration
	) async throws -> ProvisionedGuest {
		let goldenURL: URL = try resolver.resolve(golden)
		guard memoryGiB > 0, UInt64(memoryGiB) <= UInt64.max >> 30 else {
			throw NymphError.internalFailure("memory_gib out of range: \(memoryGiB)")
		}
		let goldenBundle: GoldenBundle
		do {
			goldenBundle = try GoldenBundle.load(from: goldenURL)
		} catch {
			throw NymphError.goldenNotFound(golden)
		}
		let destination: URL = resolver.cloneDestination(forGolden: goldenURL, id: UUID().uuidString)
		let clone: EphemeralBundle = try clone(goldenBundle, to: destination)
		let session: MacGuestSession
		do {
			session = try MacGuestSession(
				bundle: clone,
				cpuCount: cpus,
				memoryBytes: UInt64(memoryGiB) * 1_073_741_824,
				readinessTimeout: readinessTimeout
			)
		} catch {
			try? cloner.destroy(clone)
			throw NymphError.cloneFailed("session init failed: \(error)")
		}
		let control = RealGuestControl(
			session: session,
			exec: MacGuestExec(identity: hostKey, username: username),
			clone: clone,
			cloner: cloner
		)
		return ProvisionedGuest(control: control, goldenAlias: golden, clonePath: destination)
	}

	// MARK: Private

	/// nymph 穩定身份鑰。
	private let hostKey: NymphHostKey

	/// golden 解析器。
	private let resolver: GoldenResolver

	/// SSH 連入帳號。
	private let username: String

	/// CoW 複製器。
	private let cloner: MacGuestCloner

	/// 建 `.mayfly-clones` 落點 parent、clonefile；`MacGuestClonerError` 映成 cloneFailed。
	private func clone(_ golden: GoldenBundle, to destination: URL) throws -> EphemeralBundle {
		do {
			try FileManager.default.createDirectory(
				at: destination.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			return try cloner.clone(golden, to: destination)
		} catch {
			throw NymphError.cloneFailed(String(describing: error))
		}
	}
}

/// ``GuestControl`` 的真機實作：把 store 的抽象動作轉成引擎呼叫。VM 活在 `session`（actor）
/// 內；exec 經 ``startExec(_:standardInput:workingDirectory:environment:standardOutput:standardError:)``
/// 走 `MacGuestExec.start`（先現查 lease IP）；`MacGuestExecError` 在此映成
/// ``NymphError``（傳輸層錯誤面）。
///
/// 同步 exec 與背景 exec 都經同一個可取消的入口啟動、登記在 ``running``，destroy／drain 才收得到
/// 進行中的命令。
struct RealGuestControl: GuestControl {

	/// VM session（actor）。
	let session: MacGuestSession

	/// guest 內執行器（SSH）。
	let exec: MacGuestExec

	/// 可拋 clone bundle。
	let clone: EphemeralBundle

	/// CoW 複製器（destroy clone 用）。
	let cloner: MacGuestCloner

	/// 進行中的命令。
	internal let running: RunningGuestCommands = .init()

	func start() async throws {
		try await session.start()
	}

	func waitUntilReady() async throws -> String? {
		try await session.waitUntilReady()
	}

	func currentState() async -> SessionState {
		await promoteIfBooting()
		switch await session.state {
		case .idle:
			return .idle

		case .booting:
			return .booting

		case .ready:
			return .ready

		case .stopped:
			return .stopped
		}
	}

	func currentIP() async -> String? {
		guard case let .ready(readinessIP) = await session.state else {
			return nil
		}
		let metadataURL: URL = MacGuestBundleLayout.metadata(in: clone.bundle)
		if
			let data = try? Data(contentsOf: metadataURL),
			let metadata = try? JSONDecoder().decode(BundleMetadata.self, from: data),
			let live = MacGuestLease.currentIP(macAddress: metadata.macAddress) {
			return live
		}
		return readinessIP
	}

	func forceStop() async throws {
		try await session.forceStop()
	}

	func gracefulStop(within grace: Duration) async throws {
		_ = try await session.ensureStopped(within: grace)
	}

	func exec(
		_ command: [String],
		timeout: Duration?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> GuestExecResult {
		// 同步路徑回全文、不截斷：緩衝不設上限。
		let standardOutput: OutputTailBuffer = .init(capacity: .max)
		let standardError: OutputTailBuffer = .init(capacity: .max)
		let execution: any GuestExecution = try await startExec(
			command,
			standardInput: standardInput,
			workingDirectory: workingDirectory,
			environment: environment,
			standardOutput: standardOutput,
			standardError: standardError
		)
		switch await execution.wait(timeout: timeout) {
		case let .exited(exitCode):
			return GuestExecResult(
				standardOutput: standardOutput.snapshot().text,
				standardError: standardError.snapshot().text,
				exitCode: exitCode
			)
		case .timedOut:
			throw NymphError.execTimedOut
		case .cancelled:
			throw NymphError.execCancelled
		case let .transportFailure(detail):
			throw NymphError.transportFailure(detail)
		}
	}

	/// 現查 IP 後以 `MacGuestExec.start` 啟動，並登記在 ``running``——destroy／drain 的取消靠這份登記。
	/// - Parameters:
	///   - command: 遠端命令 argv。
	///   - standardInput: 餵給 stdin 的文字。
	///   - workingDirectory: 遠端 `cd` 的目錄。
	///   - environment: 額外環境變數。
	///   - standardOutput: stdout 的落點。
	///   - standardError: stderr 的落點。
	/// - Returns: 執行中的命令。
	internal func startExec(
		_ command: [String],
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String],
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) async throws -> any GuestExecution {
		await promoteIfBooting()
		guard case .ready = await session.state else {
			throw NymphError.notReady
		}
		// 與同步 `run` 的 session 版同一套解法：現查 host lease、退回 readiness 解出的 IP。
		guard let ipAddress: String = await currentIP() else {
			throw NymphError.ipUnavailable
		}
		let handle: MacGuestExecHandle
		do {
			handle = try exec.start(
				command,
				onHost: ipAddress,
				standardInput: standardInput,
				workingDirectory: workingDirectory,
				environment: environment,
				standardOutput: standardOutput,
				standardError: standardError
			)
		} catch let error as MacGuestExecError {
			throw RealGuestControl.map(error)
		}
		running.track(handle)
		return handle
	}

	/// 每條取消各開一個 task、不等：終止流程要另開一趟連線，guest 失聯時會等到連線上限，
	/// 呼叫端（destroy／drain）不該被這段卡住。
	internal func cancelRunningCommands() async {
		for execution in running.current() {
			Task {
				await execution.cancel()
			}
		}
	}

	func destroyClone() throws {
		try cloner.destroy(clone)
	}

	/// session 還在 `.booting` 時補探一次（`MacGuestSession.promoteIfReady()`，現查 host lease）。
	///
	/// readiness 逾時的 session 停在 `.booting`，之後要靠查狀態或 exec 這兩個入口把它帶起來
	/// ——`--no-wait` 的 spawn 根本沒等過，開機慢於 readinessTimeout 的 guest 也是如此。與
	/// Linux 側 `status`／`exec` 各自補探一次的收法對稱。
	private func promoteIfBooting() async {
		guard await session.state == .booting else { return }
		await session.promoteIfReady()
	}

	/// `MacGuestExecError`（引擎傳輸面）→ ``NymphError``（daemon 工具面）。
	private static func map(_ error: MacGuestExecError) -> NymphError {
		switch error {
		case .notReady:
			return .notReady

		case .ipUnavailable:
			return .ipUnavailable

		case let .transportFailure(detail):
			return .transportFailure(detail)

		case .timedOut:
			return .execTimedOut

		case let .launchFailed(detail):
			return .transportFailure("ssh launch failed: \(detail)")
		}
	}
}

#endif
