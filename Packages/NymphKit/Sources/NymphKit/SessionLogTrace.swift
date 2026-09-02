//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 單一操作的量測脈絡：`ContinuousClock` 起點、逐段落點、事件欄位草稿。只在 sink 非 nil 時
/// 建立；活在 ``SessionStore`` 這個 actor 內、不跨隔離，因此不需 `Sendable`。用 class 而非
/// struct：要在 async 區塊內被逐段改寫，免 `inout` 穿越 `await`。
internal final class SessionLogTrace {

	/// 起一段量測：記下操作與該操作一開始就知道的欄位，並把起點與第一個段落點都設在此刻。
	internal init(
		operation: SessionLogEvent.Operation,
		sessionID: String? = nil,
		golden: String? = nil,
		kind: GuestKind? = nil,
		command: String? = nil,
		force: Bool? = nil
	) {
		let clock: ContinuousClock = .init()
		let now: ContinuousClock.Instant = clock.now
		self.clock = clock
		self.operation = operation
		self.sessionID = sessionID
		self.golden = golden
		self.kind = kind
		self.command = command
		self.force = force
		self.started = now
		self.lastMark = now
	}

	/// session id——spawn 鑄好 handle 後才補得上。
	internal var sessionID: String?

	/// 操作收斂後的狀態（spawn／status 補填）。
	internal var state: SessionState?

	/// 遠端命令結束碼（execute 成功後補填）。
	internal var exitCode: Int32?

	/// 記下「上一落點到現在」為一段、並把落點推到現在。呼叫端只在該段跑完後呼叫——擲錯的段
	/// 因此不入列，錯誤路徑不需要任何額外程式。
	internal func mark(_ name: SessionLogEvent.Segment.Name) {
		let now: ContinuousClock.Instant = clock.now
		segments.append(SessionLogEvent.Segment(name: name, duration: lastMark.duration(to: now)))
		lastMark = now
	}

	/// 收尾：total 從起點量到現在，組成事件。
	internal func finish(timestamp: Date, outcome: SessionLogEvent.Outcome) -> SessionLogEvent {
		SessionLogEvent(
			timestamp: timestamp,
			operation: operation,
			sessionID: sessionID,
			golden: golden,
			kind: kind,
			command: command,
			force: force,
			segments: segments,
			total: started.duration(to: clock.now),
			outcome: outcome,
			state: state,
			exitCode: exitCode
		)
	}

	/// 段與總耗時的時間源。
	private let clock: ContinuousClock

	/// 被記錄的操作。
	private let operation: SessionLogEvent.Operation

	/// golden 別名（僅 spawn）。
	private let golden: String?

	/// guest 種類（僅 spawn）。
	private let kind: GuestKind?

	/// 遠端命令的 argv[0]（僅 execute）。
	private let command: String?

	/// 停機模式（僅 destroy）。
	private let force: Bool?

	/// 進入操作的時刻。
	private let started: ContinuousClock.Instant

	/// 上一個段落點。
	private var lastMark: ContinuousClock.Instant

	/// 已完成的段。
	private var segments: [SessionLogEvent.Segment] = []
}
