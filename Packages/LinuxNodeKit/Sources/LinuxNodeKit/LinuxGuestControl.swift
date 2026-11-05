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

	/// - Parameters:
	///   - manager: 建出本容器的 manager，供 ``destroyClone()`` 回收。
	///   - container: 容器物件。
	///   - containerID: 容器 id。
	///   - readinessTimeout: readiness 等待上限。
	///   - network: 本容器所在的共用網路；`nil`＝未接網路，``currentIP()`` 恆回 `nil`。
	init(
		manager: ContainerManager,
		container: LinuxContainer,
		containerID: String,
		readinessTimeout: Duration,
		network: LinuxContainerNetwork? = nil
	) {
		self.manager = manager
		self.container = container
		self.containerID = containerID
		self.readinessTimeout = readinessTimeout
		self.network = network
	}

	func start() async throws {
		let canStart: Bool = withLock {
			guard lifecycleState == .idle else { return false }
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
		let state: SessionState = withLock { lifecycleState }
		// 已被 status／exec 的隨手探測升成 .ready 時直接回報，不再空等一輪。
		guard state != .ready else { return await currentIP() }
		guard state == .booting else { return nil }
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: readinessTimeout)
		while clock.now < deadline {
			if await probeReady() {
				withLock { lifecycleState = .ready }
				return await currentIP()
			}
			try? await Task.sleep(for: .milliseconds(LinuxGuestControl.readinessPollIntervalMilliseconds))
		}
		return nil
	}

	func currentState() async -> SessionState {
		if withLock({ lifecycleState }) == .booting {
			await promoteIfReady()
		}
		return withLock { lifecycleState }
	}

	/// 回報容器在共用網路上配到的 IPv4 位址。
	///
	/// 位址由 ``LinuxContainerNetwork`` 在 `ContainerManager.create` 配發介面的當下記下——
	/// 不向 guest 內部查詢，因此 boot 尚未完成時就已可回報。容器未接網路（引擎建構時
	/// 未傳網路）時恆為 `nil`。
	func currentIP() async -> String? {
		network?.ipv4Address(for: containerID)
	}

	func forceStop() async throws {
		let shouldStop: Bool = withLock {
			guard lifecycleState != .idle, lifecycleState != .stopped else { return false }
			lifecycleState = .stopped
			return true
		}
		guard shouldStop else { return }
		do {
			try await container.stop()
		} catch {
			throw NymphError.internalFailure("linux container stop failed: \(error)")
		}
	}

	/// Linux 容器無 macOS `MacGuestSession` 式「guest 自行回報停機」通道（vminitd 無此
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
		if withLock({ lifecycleState }) == .booting {
			await promoteIfReady()
		}
		guard withLock({ lifecycleState }) == .ready else { throw NymphError.notReady }
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

	// MARK: Internal

	/// 本容器的 image store（建出容器的 manager 所用的那一份）。
	///
	/// 燒映像時要從這裡讀 base 映像的 config，再把固化出來的映像載回同一份 store。
	internal var imageStore: ImageStore {
		withLock { manager.imageStore }
	}

	/// 執行一條命令，輸出邊跑邊交給呼叫端的 ``Writer``、不留在記憶體。
	///
	/// 給輸出大到不該整份收進記憶體（rootfs 匯出）或需要即時轉給操作者看的命令用。與
	/// ``exec(_:timeout:standardInput:workingDirectory:environment:)`` 同一道 readiness 檢查，
	/// 但**不帶逾時**：`LinuxProcess.wait(timeoutInSeconds:)` 逾時只擲錯、不收行程，要上限得由
	/// 呼叫端整台 ``forceStop()``——停機後這裡的等待隨之結束並擲錯。
	///
	/// - Parameters:
	///   - command: argv。
	///   - standardInput: 送進 stdin 的位元組；`nil`＝不接 stdin。
	///   - standardOutput: stdout 的去處。
	///   - standardError: stderr 的去處。
	/// - Returns: 命令的結束碼。
	/// - Throws: ``NymphError/notReady``，或啟動、等待行程時的錯誤（經 ``LinuxGuestErrorMapping`` 轉換）。
	internal func stream(
		_ command: [String],
		standardInput: Data?,
		standardOutput: any Writer,
		standardError: any Writer
	) async throws -> Int32 {
		if withLock({ lifecycleState }) == .booting {
			await promoteIfReady()
		}
		guard withLock({ lifecycleState }) == .ready else { throw NymphError.notReady }
		do {
			return try await launch(
				Invocation(command: command, standardInput: standardInput),
				standardOutput: standardOutput,
				standardError: standardError
			)
		} catch let error as NymphError {
			throw error
		} catch {
			throw LinuxGuestErrorMapping.map(error)
		}
	}

	// MARK: Private

	/// 一次 exec 的命令與執行條件。
	private struct Invocation: Sendable {

		/// argv。
		internal let command: [String]

		/// 等待上限（秒）；`nil`＝不設。
		internal var timeoutSeconds: Int64?

		/// 送進 stdin 的位元組；`nil`＝不接 stdin。
		internal var standardInput: Data?

		/// 工作目錄；`nil`＝`/`。
		internal var workingDirectory: String?

		/// 疊加在預設環境變數之上的變數。
		internal var environment: [String: String] = [:]
	}

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

	private let network: LinuxContainerNetwork?

	private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	/// 探測一次，通了就把狀態升成 `.ready`（冪等、只從 `.booting` 升）。
	///
	/// `.ready` 的轉態不能只掛在 ``waitUntilReady()``——`--no-wait` 的 spawn 根本不呼叫它，
	/// 狀態會永停 `.booting`，使 ``exec(_:timeout:standardInput:workingDirectory:environment:)``
	/// 的 readiness guard 恆假、該 session 只能 destroy。故 status／exec 兩個入口遇 `.booting`
	/// 時各自補探一次，讓收斂不依賴呼叫端有沒有等。
	private func promoteIfReady() async {
		guard await probeReady() else { return }
		withLock {
			if lifecycleState == .booting {
				lifecycleState = .ready
			}
		}
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
		let invocation: Invocation = .init(
			command: command,
			timeoutSeconds: timeoutSeconds,
			standardInput: standardInput.map { Data($0.utf8) },
			workingDirectory: workingDirectory,
			environment: environment
		)
		let exitCode: Int32 = try await launch(invocation, standardOutput: stdout, standardError: stderr)
		return GuestExecResult(
			standardOutput: String(data: stdout.data, encoding: .utf8) ?? "",
			standardError: String(data: stderr.data, encoding: .utf8) ?? "",
			exitCode: exitCode
		)
	}

	/// 起一個 exec 行程、等它結束；輸出寫進呼叫端給的 ``Writer``。
	/// - Parameters:
	///   - invocation: 命令與執行條件。
	///   - standardOutput: stdout 的去處。
	///   - standardError: stderr 的去處。
	/// - Returns: 結束碼。
	/// - Throws: 啟動或等待行程時的 Containerization 錯誤。
	private func launch(
		_ invocation: Invocation,
		standardOutput: any Writer,
		standardError: any Writer
	) async throws -> Int32 {
		let processID: String = "exec-\(UUID().uuidString)"
		let process: LinuxProcess = try await container.exec(processID) { configuration in
			configuration.arguments = invocation.command
			configuration.workingDirectory = invocation.workingDirectory ?? "/"
			// 附加、不取代預設 environmentVariables——保留內建 PATH，呼叫端額外變數
			// 疊加上去，避免「一傳自訂環境變數就丟失 PATH」的落地陷阱。
			if !invocation.environment.isEmpty {
				configuration.environmentVariables.append(contentsOf: invocation.environment.map { "\($0.key)=\($0.value)" })
			}
			configuration.stdout = standardOutput
			configuration.stderr = standardError
			if let standardInput: Data = invocation.standardInput {
				configuration.stdin = StaticInputStream(data: standardInput)
			}
		}
		try await process.start()
		let status: ExitStatus = try await process.wait(timeoutInSeconds: invocation.timeoutSeconds)
		return status.exitCode
	}
}

#endif
