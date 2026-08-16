//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

// 引擎真機路徑觸碰 GuestSession（VZ、arm64 限定）與 GuestExec 的 session overload——整段
// arch gate。核心 SessionStore / 協議 / socket 皆 arch-neutral、以 fake 驅動可跨 arch 測；
// 只有這層真接引擎。非 arm64 由 `mayfly nymph` 命令層擋下（比照 RunCommand）。
#if arch(arm64)

/// ``GuestEngine`` 的真機實作：golden 別名 → `clonefile` 落地 → 建 `GuestSession`（未 start）
/// → 包成 ``RealGuestControl``。組合現有引擎正本（`GuestCloner` / `GuestSession` /
/// `GuestExec` / `GuestLease`），本層只做別名解析、clone 落點、身份鑰接線——不改引擎。
public struct RealGuestEngine: GuestEngine {

	// MARK: Public

	/// - Parameters:
	///   - hostKey: nymph 穩定身份鑰（`mayfly nymph` 首啟 loadOrGenerate）。
	///   - resolver: golden 別名解析 + clone 落點（NY-3）。
	///   - username: SSH 連入的 guest 帳號（golden 注入公鑰的那個），預設 `runner`。
	///   - cloner: CoW 複製器。
	public init(
		hostKey: NymphHostKey,
		resolver: GoldenResolver,
		username: String = "runner",
		cloner: GuestCloner = GuestCloner()
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
		let session: GuestSession
		do {
			session = try GuestSession(
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
			exec: GuestExec(identity: hostKey, username: username),
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
	private let cloner: GuestCloner

	/// 建 `.mayfly-clones` 落點 parent、clonefile；`GuestClonerError` 映成 cloneFailed。
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
/// 內；exec 走 `GuestExec` 的 session overload（現查 lease IP）；`GuestExecError` 在此映成
/// ``NymphError``（傳輸層錯誤面）。
struct RealGuestControl: GuestControl {

	/// VM session（actor）。
	let session: GuestSession

	/// guest 內執行器（SSH）。
	let exec: GuestExec

	/// 可拋 clone bundle。
	let clone: EphemeralBundle

	/// CoW 複製器（destroy clone 用）。
	let cloner: GuestCloner

	func start() async throws {
		try await session.start()
	}

	func waitUntilReady() async throws -> String? {
		try await session.waitUntilReady()
	}

	func currentState() async -> SessionState {
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
		let metadataURL: URL = GuestBundleLayout.metadata(in: clone.bundle)
		if
			let data = try? Data(contentsOf: metadataURL),
			let metadata = try? JSONDecoder().decode(BundleMetadata.self, from: data),
			let live = GuestLease.currentIP(macAddress: metadata.macAddress) {
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
		do {
			return try await exec.run(
				command,
				on: session,
				timeout: timeout,
				standardInput: standardInput,
				workingDirectory: workingDirectory,
				environment: environment
			)
		} catch let error as GuestExecError {
			throw RealGuestControl.map(error)
		}
	}

	func destroyClone() throws {
		try cloner.destroy(clone)
	}

	/// `GuestExecError`（引擎傳輸面）→ ``NymphError``（daemon 工具面）。
	private static func map(_ error: GuestExecError) -> NymphError {
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
