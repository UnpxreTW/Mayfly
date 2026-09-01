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

	/// 等 readiness 收斂、回解出的 IP；逾時 / 提早停回 nil（不擲錯——NY-1 降級語義）。
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

	/// 刪掉此 guest 的 clone bundle（destroy 收尾；stop 之後呼叫）。
	func destroyClone() throws
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
