//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

// MARK: - SessionLogEventTests

private final class SessionLogEventTests {

	/// spawn 行：三段耗時、golden／kind、收斂後狀態，欄序固定。
	@Test
	private func `spawn line matches template`() {
		let event: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: "mfly-3fa2c1d9",
			golden: "base",
			kind: .mac,
			segments: [
				SessionLogEvent.Segment(name: .provision, duration: .seconds(1) + .milliseconds(204)),
				SessionLogEvent.Segment(name: .start, duration: .milliseconds(312)),
				SessionLogEvent.Segment(name: .ready, duration: .seconds(22) + .milliseconds(981))
			],
			total: .seconds(24) + .milliseconds(770),
			outcome: .ok,
			state: .ready
		)
		#expect(event.description == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=spawn id=mfly-3fa2c1d9 golden=base kind=mac \
		provision=1.204s start=0.312s ready=22.981s total=24.770s result=ok state=ready
		""")
	}

	/// execute 行：argv[0]、exec 段、結束碼（非零是資料、result 仍是 ok）。
	@Test
	private func `execute line carries argv0 exit and exec segment`() {
		let event: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .execute,
			sessionID: "mfly-3fa2c1d9",
			command: "security",
			segments: [SessionLogEvent.Segment(name: .exec, duration: .seconds(3) + .milliseconds(417))],
			total: .seconds(3) + .milliseconds(418),
			outcome: .ok,
			exitCode: 1
		)
		#expect(event.description == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=execute id=mfly-3fa2c1d9 command=security \
		exec=3.417s total=3.418s result=ok exit=1
		""")
	}

	/// status 行只有總耗時與狀態；destroy 行帶停機模式與 stop 段。
	@Test
	private func `status and destroy lines match template`() {
		let status: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .status,
			sessionID: "mfly-3fa2c1d9",
			segments: [],
			total: .milliseconds(2),
			outcome: .ok,
			state: .ready
		)
		#expect(status.description == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=status id=mfly-3fa2c1d9 total=0.002s result=ok state=ready
		""")
		let destroy: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .destroy,
			sessionID: "mfly-3fa2c1d9",
			force: true,
			segments: [SessionLogEvent.Segment(name: .stop, duration: .milliseconds(541))],
			total: .milliseconds(563),
			outcome: .ok
		)
		#expect(destroy.description == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=destroy id=mfly-3fa2c1d9 force=true stop=0.541s \
		total=0.563s result=ok
		""")
	}

	/// provision 就失敗：id 與三段皆未達、印佔位字元，`error=` 收在最後一欄。
	@Test
	private func `unreached columns render as dash`() {
		let event: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: nil,
			golden: "nope",
			kind: .mac,
			segments: [],
			total: .milliseconds(4),
			outcome: .error(ToolError(.goldenNotFound("nope")))
		)
		#expect(event.description == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=spawn id=- golden=nope kind=mac provision=- start=- \
		ready=- total=0.004s result=error state=- error=golden_not_found: golden alias not found: nope
		""")
	}

	/// 錯誤訊息壓成單行：換行與 tab 換空白、連續空白收一個、過長截斷並標省略號。
	@Test
	private func `error detail collapses to one line and truncates`() {
		let message: String = "boom\nsecond\tline " + String(repeating: "z", count: 300)
		let event: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .status,
			sessionID: "mfly-3fa2c1d9",
			segments: [],
			total: .milliseconds(1),
			outcome: .error(ToolError(code: "internal_error", message: message))
		)
		let line: String = event.description
		#expect(!line.contains("\n"))
		#expect(!line.contains("\t"))
		#expect(line == """
		nymph: session ts=1970-01-01T00:00:00.000Z op=status id=mfly-3fa2c1d9 total=0.001s result=error \
		state=- error=internal_error: boom second line \(String(repeating: "z", count: 183))…
		""")
	}

	/// 耗時一律三位小數、無條件捨去——進位會讓「剛好沒到」的段看起來達標。
	@Test
	private func `duration renders three decimals truncated`() {
		#expect(Self.totalColumn(of: .milliseconds(4)) == "total=0.004s")
		#expect(Self.totalColumn(of: .seconds(24) + .milliseconds(770)) == "total=24.770s")
		#expect(Self.totalColumn(of: .zero) == "total=0.000s")
		#expect(Self.totalColumn(of: .microseconds(999)) == "total=0.000s")
	}

	/// 外來字串欄的空白與控制字元換成 `_`（前者撐破以空白分欄的格式、後者會被終端解譯成游標
	/// 指令）、過長截斷。`id` 同受此限——它來自請求，夾帶換行就能偽造出第二行紀錄。
	@Test
	private func `identifier golden and command sanitize unsafe characters`() {
		let spawn: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: "mfly-3fa2c1d9",
			golden: "my golden",
			kind: .mac,
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(spawn.description.contains("golden=my_golden"))
		let execute: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .execute,
			sessionID: "mfly-3fa2c1d9",
			command: "ec\tho",
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(execute.description.contains("command=ec_ho"))
		let long: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .execute,
			sessionID: "mfly-3fa2c1d9",
			command: String(repeating: "c", count: 80),
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(long.description.contains("command=" + String(repeating: "c", count: 64) + " "))
		let forged: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .status,
			sessionID: "ghost\nnymph: session op=spawn",
			segments: [],
			total: .zero,
			outcome: .ok,
			state: .ready
		)
		#expect(!forged.description.contains("\n"))
		#expect(forged.description.contains("id=ghost_nymph:_session_op=spawn "))
		let escaped: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: "mfly-3fa2c1d9",
			golden: "x\u{1B}[1Kbase",
			kind: .mac,
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(escaped.description.contains("golden=x_[1Kbase"))
	}

	/// 起訖兩端各給一句話，句中帶著 session id——只讀紀錄那一面的人靠它找回資料行。
	@Test
	private func `lifecycle message covers both ends of a session`() {
		let began: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: "mfly-3fa2c1d9",
			golden: "base",
			kind: .mac,
			segments: [],
			total: .zero,
			outcome: .ok,
			state: .ready
		)
		let ended: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .destroy,
			sessionID: "mfly-3fa2c1d9",
			force: true,
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(began.lifecycleMessage == "session mfly-3fa2c1d9 began; phase timings in the session line with the same id")
		#expect(ended.lifecycleMessage == "session mfly-3fa2c1d9 ended; phase timings in the session line with the same id")
	}

	/// 兩端之間的操作不是端點：execute 與 status 不出生命週期那一行。
	@Test
	private func `lifecycle message skips operations between both ends`() {
		let executed: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .execute,
			sessionID: "mfly-3fa2c1d9",
			command: "security",
			segments: [],
			total: .zero,
			outcome: .ok,
			exitCode: 0
		)
		let queried: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .status,
			sessionID: "mfly-3fa2c1d9",
			segments: [],
			total: .zero,
			outcome: .ok,
			state: .ready
		)
		#expect(executed.lifecycleMessage == nil)
		#expect(queried.lifecycleMessage == nil)
	}

	/// 沒收斂成功就沒有端點：擲錯的 spawn 沒有活著的 session、擲錯的 destroy 沒把 session 收掉。
	@Test
	private func `lifecycle message skips failed operations`() {
		let failedSpawn: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: "mfly-3fa2c1d9",
			golden: "base",
			kind: .mac,
			segments: [],
			total: .zero,
			outcome: .error(ToolError(code: "internal_error", message: "boom"))
		)
		let failedDestroy: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .destroy,
			sessionID: "mfly-3fa2c1d9",
			force: false,
			segments: [],
			total: .zero,
			outcome: .error(ToolError(code: "no_such_id", message: "no such id"))
		)
		#expect(failedSpawn.lifecycleMessage == nil)
		#expect(failedDestroy.lifecycleMessage == nil)
	}

	/// 連 id 都還沒鑄出來的 spawn（provision 階段就失敗）同樣不出那一行。
	@Test
	private func `lifecycle message needs a session id`() {
		let event: SessionLogEvent = .init(
			timestamp: Self.timestamp,
			operation: .spawn,
			sessionID: nil,
			golden: "base",
			kind: .mac,
			segments: [],
			total: .zero,
			outcome: .ok
		)
		#expect(event.lifecycleMessage == nil)
	}

	/// 固定時間戳——用整數秒，避免浮點毫秒讓期望行變得含糊。
	private static let timestamp: Date = .init(timeIntervalSince1970: 0)

	/// 只為驗耗時渲染而組的最小事件，取其 `total=` 欄。
	private static func totalColumn(of total: Duration) -> String {
		let event: SessionLogEvent = .init(
			timestamp: timestamp,
			operation: .status,
			sessionID: "mfly-3fa2c1d9",
			segments: [],
			total: total,
			outcome: .ok,
			state: .ready
		)
		return event.description.split(separator: " ").first { $0.hasPrefix("total=") }.map(String.init) ?? ""
	}
}
