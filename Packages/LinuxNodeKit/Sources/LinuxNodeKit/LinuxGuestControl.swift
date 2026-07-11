//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation
import MachineKit
import NymphKit

// LinuxGuestControl 觸碰 Containerization 的真容器 API——整檔 arch gate，比照
// RealGuestEngine.swift（NymphKit/RealGuestEngine.swift）。核心邏輯（LinuxImageResolver／
// LinuxKernelCache／LinuxKernelProvisioner／LinuxGuestErrorMapping）arch-neutral、可跨
// arch 以 fake 測；只有這層真接引擎。

#if arch(arm64)

/// ``GuestControl`` 的 Linux 實作：把 store 的抽象動作轉成 ``LinuxContainer`` 呼叫。容器
/// 主行程恆跑 keep-alive 指令（``keepAliveArguments``）撐住 VM 生命週期，真正的工作命令
/// 走 `exec(_:timeout:standardInput:workingDirectory:environment:)` 的 `container.exec`
/// （vminitd GRPC over vsock）。
///
/// 用鎖護 class（非 actor）：``GuestControl/destroyClone()`` 是同步協定要求，actor
/// isolated 方法無法滿足同步 protocol requirement；`ContainerManager` 又是
/// `mutating func` 的 struct，需要可變落點——鎖只護住 `manager` / 生命週期旗標本身的
/// 同步存取，不跨 `await` 持鎖（`container` 本身是 Containerization 內部以
/// `AsyncMutex` 自行序列化的 `Sendable` class，呼叫端不需額外鎖）。
final class LinuxGuestControl: GuestControl, @unchecked Sendable {

	/// 容器主行程 keep-alive 指令：無限期存活、讓 exec 能隨時注入額外行程。持續時間非
	/// 真無限（busybox `sleep` 不保證支援 `infinity` 關鍵字）、選一個遠超合理 session
	/// 存活期的秒數；正式 idle-timeout / 生命週期政策留後續切片。
	static let keepAliveArguments: [String] = ["/bin/sleep", "2147483647"]

	init(
		manager: ContainerManager,
		container: LinuxContainer,
		containerID: String,
		readinessTimeout: Duration
	) {
		self.manager = manager
		self.container = container
		self.containerID = containerID
		self.readinessTimeout = readinessTimeout
	}

	func start() async throws {
		let canStart: Bool = withLock {
			guard lifecycleState == .idle else {
				return false
			}
			lifecycleState = .booting
			return true
		}
		guard canStart else {
			throw NymphError.internalFailure("start() called on non-idle linux guest \(containerID)")
		}
		do {
			try await container.create()
			try await container.start()
		} catch {
			withLock { lifecycleState = .stopped }
			throw NymphError.cloneFailed("linux container create/start failed: \(error)")
		}
	}

	func waitUntilReady() async throws -> String? {
		guard withLock({ lifecycleState }) == .booting else {
			return nil
		}
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: readinessTimeout)
		while clock.now < deadline {
			if await probeReady() {
				withLock { lifecycleState = .ready }
				// 未啟用容器網路（見型別文件），無 IP 可回。
				return nil
			}
			try? await Task.sleep(for: .milliseconds(LinuxGuestControl.readinessPollIntervalMilliseconds))
		}
		return nil
	}

	func currentState() async -> SessionState {
		withLock { lifecycleState }
	}

	func currentIP() async -> String? {
		// M1 未啟用容器網路（host↔容器連通性未解、非本層可控）——無 IP 可回。
		// SessionStore 依 IP 非 nil 判斷 ready 的相容處理留後續整合切片解決。
		nil
	}

	func forceStop() async throws {
		let shouldStop: Bool = withLock {
			guard lifecycleState != .idle, lifecycleState != .stopped else {
				return false
			}
			lifecycleState = .stopped
			return true
		}
		guard shouldStop else {
			return
		}
		do {
			try await container.stop()
		} catch {
			throw NymphError.internalFailure("linux container stop failed: \(error)")
		}
	}

	/// Linux 容器無 macOS `GuestSession` 式「guest 自行回報停機」通道（vminitd 無此
	/// 語意）；優雅停機退化為直接 forceStop——grace 窗口留待未來主行程支援 SIGTERM
	/// 優雅結束時補。
	func gracefulStop(within grace: Duration) async throws {
		try await forceStop()
	}

	func exec(
		_ command: [String],
		timeout: Duration?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> GuestExecResult {
		guard withLock({ lifecycleState }) == .ready else {
			throw NymphError.notReady
		}
		do {
			return try await runCommand(
				command,
				timeoutSeconds: timeout?.components.seconds,
				standardInput: standardInput,
				workingDirectory: workingDirectory,
				environment: environment
			)
		} catch let error as NymphError {
			throw error
		} catch {
			throw LinuxGuestErrorMapping.map(error)
		}
	}

	func destroyClone() throws {
		try withLock { try manager.delete(containerID) }
	}

	// MARK: Private

	/// readiness 探測輪詢間隔（毫秒）。
	private static let readinessPollIntervalMilliseconds: Int = 100

	/// readiness 探測單次逾時（`/bin/true` 應瞬間完成，給充裕但有界的容錯窗）。
	private static let readinessProbeTimeoutSeconds: Int64 = 5

	/// readiness 探測指令：假設 rootfs 具備 coreutils / busybox `true`（M1 範圍內的
	/// alias 皆符合，見 ``LinuxImageResolver``）。
	private static let readinessProbeCommand: [String] = ["/bin/true"]

	private let lock: NSLock = .init()

	private var manager: ContainerManager

	private var lifecycleState: SessionState = .idle

	/// 容器物件本身是 Containerization 內部以 `AsyncMutex` 自行序列化的 `Sendable`
	/// class，呼叫端不需額外鎖。
	private let container: LinuxContainer

	private let containerID: String

	private let readinessTimeout: Duration

	private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	private func probeReady() async -> Bool {
		let result: GuestExecResult? = try? await runCommand(
			LinuxGuestControl.readinessProbeCommand,
			timeoutSeconds: LinuxGuestControl.readinessProbeTimeoutSeconds,
			standardInput: nil,
			workingDirectory: nil,
			environment: [:]
		)
		return result?.exitCode == 0
	}

	/// 實際跑一次 exec、收集輸出——``exec(_:timeout:standardInput:workingDirectory:environment:)``
	/// 與 ``probeReady()`` 共用，readiness 前的 guard 由呼叫端各自決定（probe 故意在
	/// `.booting` 時就跑、測 vsock 通道是否已通）。
	private func runCommand(
		_ command: [String],
		timeoutSeconds: Int64?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> GuestExecResult {
		let stdout: BufferedOutputWriter = .init()
		let stderr: BufferedOutputWriter = .init()
		let processID: String = "exec-\(UUID().uuidString)"
		let process: LinuxProcess = try await container.exec(processID) { configuration in
			configuration.arguments = command
			configuration.workingDirectory = workingDirectory ?? "/"
			// 附加、不取代預設 environmentVariables——保留內建 PATH，呼叫端額外變數
			// 疊加上去，避免「一傳自訂環境變數就丟失 PATH」的落地陷阱。
			if !environment.isEmpty {
				configuration.environmentVariables.append(contentsOf: environment.map { "\($0.key)=\($0.value)" })
			}
			configuration.stdout = stdout
			configuration.stderr = stderr
			if let standardInput {
				configuration.stdin = StaticInputStream(data: Data(standardInput.utf8))
			}
		}
		try await process.start()
		let status: ExitStatus = try await process.wait(timeoutInSeconds: timeoutSeconds)
		return GuestExecResult(
			standardOutput: String(data: stdout.data, encoding: .utf8) ?? "",
			standardError: String(data: stderr.data, encoding: .utf8) ?? "",
			exitCode: status.exitCode
		)
	}
}

#endif