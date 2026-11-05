//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

/// 一台受 daemon 管的 guest 的控制面——`SessionStore` 只透過此協議驅動 VM 生命週期與
/// exec，**不直接觸碰引擎**。真機由 arm64 的 ``RealGuestControl`` 包 `MacGuestSession` +
/// `MacGuestExec`；單元測試以 fake 取代（無需真開 VM / 真 SSH），把 store 的編排邏輯與 VM
/// 隔開來測——這是本層抽象的唯一理由。
public protocol GuestControl: Sendable {

	/// 開機（一次性；重呼由實作擲錯）。
	func start() async throws

	/// 等 readiness 收斂、回解出的 IP；逾時 / 提早停回 nil（不擲錯——逾時是降級、不是錯誤）。
	func waitUntilReady() async throws -> String?

	/// 目前狀態快照。
	func currentState() async -> SessionState

	/// 目前 IP 快照（未解出為 nil）。
	func currentIP() async -> String?

	/// host 硬停（ephemeral 可拋、destroy force 的收法）。
	func forceStop() async throws

	/// 等 guest 自停、逾 grace 硬停（destroy force=false 的收法）。
	func gracefulStop(within grace: Duration) async throws

	/// 在此 guest 內執行命令（SSH）。**結束碼是資料**（回在 ``GuestExecResult``）；傳輸層
	/// 失敗擲 ``NymphError``（notReady / ipUnavailable / transportFailure / execTimedOut）。
	func exec(
		_ command: [String],
		timeout: Duration?,
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String]
	) async throws -> GuestExecResult

	/// 在此 guest 內啟動命令、不等它結束：stdout／stderr 逐段寫進給定的緩衝，回一個可等待、
	/// 可取消的執行。傳輸層起不來擲 ``NymphError``（notReady / ipUnavailable / transportFailure）。
	///
	/// 預設實作擲 ``NymphError/internalFailure(_:)``——不支援背景執行的 guest 不必實作。
	func startExec(
		_ command: [String],
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String],
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) async throws -> any GuestExecution

	/// 對此 guest 上所有進行中的命令發出取消，**不等**終止流程跑完就回（destroy／drain 停機前
	/// 呼叫；終止流程要另開一趟連線，guest 失聯時會等到連線上限）。
	///
	/// 預設實作不做事。
	func cancelRunningCommands() async

	/// 刪掉此 guest 的 clone bundle（destroy 收尾；stop 之後呼叫）。
	func destroyClone() throws
}

/// ``GuestControl`` 新 requirement 的預設實作：沒有背景執行的 guest 不必實作。
extension GuestControl {

	/// 預設不支援：擲 ``NymphError/internalFailure(_:)``。
	/// - Parameters:
	///   - command: 遠端命令 argv。
	///   - standardInput: 餵給 stdin 的文字。
	///   - workingDirectory: 遠端 `cd` 的目錄。
	///   - environment: 額外環境變數。
	///   - standardOutput: stdout 的落點。
	///   - standardError: stderr 的落點。
	/// - Returns: 不回傳（恆擲錯）。
	public func startExec(
		_ command: [String],
		standardInput: String?,
		workingDirectory: String?,
		environment: [String: String],
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) async throws -> any GuestExecution {
		throw NymphError.internalFailure("detached exec is not supported for this guest")
	}

	/// 預設不做事：沒有經 ``startExec(_:standardInput:workingDirectory:environment:standardOutput:standardError:)``
	/// 啟動的命令可取消。
	public func cancelRunningCommands() async {}
}

/// golden 別名 → 一台備妥（clone 完成、尚未 start）的 guest。`SessionStore.spawn` 在
/// admission 通過後呼叫；真機由 arm64 的 ``RealGuestEngine`` 實作（解析 golden、clonefile、
/// 建 `MacGuestSession`），測試以 fake 取代。
public protocol GuestEngine: Sendable {

	/// 解析 `golden` 別名、clone 落地、備妥控制面。
	///
	/// - Throws: ``NymphError/goldenNotFound(_:)`` / ``NymphError/cloneFailed(_:)`` /
	///   ``NymphError/notAppleSilicon``。
	func provision(
		golden: String,
		cpus: Int,
		memoryGiB: Int,
		readinessTimeout: Duration
	) async throws -> ProvisionedGuest
}

/// ``GuestEngine/provision(golden:cpus:memoryGiB:readinessTimeout:)`` 的產物：控制面 +
/// 對外顯示用的 golden 別名 + clone 的 host 路徑（**僅 daemon 內部持有、不出對外回傳**、
/// 供孤兒回收登記）。
public struct ProvisionedGuest: Sendable {

	/// VM 控制面。
	public let control: any GuestControl

	/// golden 別名（回傳 / 摘要用）。
	public let goldenAlias: String

	/// clone 的 host 路徑（daemon-internal、登記給 ``CloneRegistry``）。
	public let clonePath: URL

	public init(control: any GuestControl, goldenAlias: String, clonePath: URL) {
		self.control = control
		self.goldenAlias = goldenAlias
		self.clonePath = clonePath
	}
}
