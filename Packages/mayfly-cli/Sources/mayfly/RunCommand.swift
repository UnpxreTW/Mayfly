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
import MachineKit

/// `mayfly run <clone>`：boot → readiness → 印 `READY ip=<ip|none>` → 前景長駐到
/// guest 停止或收到 SIGTERM / SIGINT（轉引擎 forceStop——ephemeral 複本可拋、硬停
/// 是預設收法）。VM 隨本行程生滅；readiness 逾時**不**自殺（`READY ip=none` 後
/// 續跑，呼叫端可再輪詢 `mayfly ip` 或放棄）。
struct RunCommand: AsyncParsableCommand {

	static let configuration: CommandConfiguration = .init(
		commandName: "run",
		abstract: "Boot a disposable clone and stay in the foreground until it stops."
	)

	/// 可拋複本路徑（`mayfly clone` 的產物；驗 ephemeral 標記）。
	@Argument(help: "Path to a disposable clone (made by `mayfly clone`).")
	var bundle: String

	/// 要求的 vCPU 數（超出 host 上限由引擎收斂）。
	@Option(help: "Virtual CPU count (clamped to host limits).")
	var cpus: Int = 4

	/// 要求的記憶體（GiB、超出 host 上限由引擎收斂）。
	@Option(name: .customLong("memory-gib"), help: "Memory in GiB (clamped to host limits).")
	var memoryGiB: UInt64 = 4

	/// readiness 等待上限（秒）；逾時印 `READY ip=none`、guest 續跑。
	@Option(name: .customLong("readiness-timeout"), help: "Readiness wait ceiling in seconds (then READY ip=none).")
	var readinessTimeoutSeconds: Int = 180

	/// 上界擋在乘法前：`memoryGiB * 2^30` 溢位是 Swift 執行期 trap（CLI 直接崩），
	/// 該給的是 usage error——不擋的話引擎的 host 上限收斂根本輪不到跑。
	func validate() throws {
		guard memoryGiB > 0, memoryGiB <= UInt64.max >> 30 else {
			throw ValidationError("--memory-gib is out of range.")
		}
	}

	func run() async throws {
#if arch(arm64)
		let clone: EphemeralBundle = try .load(from: URL(fileURLWithPath: bundle))
		let session: GuestSession = try .init(
			bundle: clone,
			cpuCount: cpus,
			memoryBytes: memoryGiB * 1_073_741_824,
			readinessTimeout: .seconds(readinessTimeoutSeconds)
		)
		try await session.start()
		// SIGTERM / SIGINT 轉 forceStop：先 SIG_IGN 停用預設終止、再掛 DispatchSource
		// ——VM 活在本行程、預設處置會讓 guest 無收斂地死。
		signal(SIGTERM, SIG_IGN)
		signal(SIGINT, SIG_IGN)
		let terminate: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGTERM)
		terminate.setEventHandler { Task { try? await session.forceStop() } }
		terminate.resume()
		let interrupt: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGINT)
		interrupt.setEventHandler { Task { try? await session.forceStop() } }
		interrupt.resume()
		let ip: String? = try await session.waitUntilReady()
		// 直接寫 handle：stdout 接 pipe 時 print 會 block-buffer，executor 讀不到行。
		FileHandle.standardOutput.write(Data("READY ip=\(ip ?? "none")\n".utf8))
		let reason: GuestStopReason = try await session.waitUntilStopped()
		// cancel 兼作生命週期錨點：source 若提早釋放、handler 隨之失效。
		terminate.cancel()
		interrupt.cancel()
		if case let .error(underlying) = reason {
			FileHandle.standardError.write(Data("guest stopped with error: \(underlying)\n".utf8))
			throw ExitCode(1)
		}
#else
		throw ValidationError("mayfly run requires Apple Silicon.")
#endif
	}
}
