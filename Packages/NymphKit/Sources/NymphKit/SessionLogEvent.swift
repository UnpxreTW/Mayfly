//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一次 store 操作的紀錄：誰（session id）、做什麼（operation）、各段花多久（segments）、總共
/// 花多久（total）、結果如何（outcome）。純資料、`Equatable` 供測試比對；單行文字形由
/// `CustomStringConvertible` 的 ``description`` 給。
public struct SessionLogEvent: Sendable, Equatable {

	/// 被記錄的 store 操作。`list`（app 定時輪詢、會洗版）與 `drain`（關機收束）刻意不記。
	public enum Operation: String, Sendable, Equatable {

		/// clone、開機、依 NY-1 收斂。
		case spawn

		/// 在既有 session 內執行遠端命令。
		case execute

		/// 查單一 session 的狀態。
		case status

		/// 停機、刪 clone、移出 table。
		case destroy
	}

	/// 操作內的一段耗時；``Name`` 的 `rawValue` 即單行紀錄裡的欄名。
	public struct Segment: Sendable, Equatable {

		/// 段名——每個值對應一處量測點。
		public enum Name: String, Sendable, Equatable {

			/// spawn：``GuestEngine`` 的 provision（別名解析、clone、session 建構）。
			case provision

			/// spawn：``GuestControl`` 的 start（開機）。
			case start

			/// spawn：waitUntilReady 到狀態／IP 收斂為止。
			case ready

			/// execute：``GuestControl`` 的 exec。
			case exec

			/// destroy：forceStop 或 gracefulStop。
			case stop
		}

		/// 段名。
		public let name: Name

		/// 該段耗時（`ContinuousClock` 量得、單調不受 wall clock 校正影響）。
		public let duration: Duration

		/// 以段名與量到的耗時組一段。
		public init(name: Name, duration: Duration) {
			self.name = name
			self.duration = duration
		}
	}

	/// 操作結果：成功、或帶穩定錯誤碼的失敗（沿用 ``ToolError`` 的 code 與 message）。
	public enum Outcome: Sendable, Equatable {

		/// 操作正常收斂。readiness 逾時降級 booting 亦屬此類（NY-1：逾時不是錯誤）。
		case ok

		/// 操作擲錯，帶對外穩定錯誤碼。
		case error(ToolError)
	}

	/// 事件時間戳（wall clock、取自 ``SessionStore`` 注入的時間源；只在 sink 開啟時讀）。
	public let timestamp: Date

	/// 被記錄的操作。
	public let operation: Operation

	/// session id；provision 階段就失敗（尚未鑄出 handle）時為 nil。
	public let sessionID: String?

	/// golden 別名（僅 spawn）。
	public let golden: String?

	/// guest 種類（僅 spawn）。
	public let kind: GuestKind?

	/// 遠端命令的 argv[0]（僅 execute；不記完整 argv——引數可能含祕密）。
	public let command: String?

	/// 停機模式（僅 destroy；true＝forceStop、false＝gracefulStop）。
	public let force: Bool?

	/// 依發生順序記錄，只收「跑完」的段：會擲錯的段（provision／start／exec）一失敗即不入列；
	/// `ready` 逾時與 `stop` 停機失敗都被上層吞掉、仍各記一段（NY-1：逾時是降級、不是錯誤）。
	/// 缺席的段印 `-`，其耗時可由 ``total`` 減已記段之和粗估——spawn 的 start 失敗另含回滾
	/// 耗時，該情況會高估。
	public let segments: [Segment]

	/// 從進入操作到發出事件的總耗時。
	public let total: Duration

	/// 結果。
	public let outcome: Outcome

	/// 操作收斂後的 session 狀態（spawn／status）。
	public let state: SessionState?

	/// 遠端命令結束碼（僅 execute 成功時；非零是資料、不是錯誤）。
	public let exitCode: Int32?

	/// 逐欄組一筆事件；不適用於該操作的欄位留預設 nil、渲染時印佔位字元。
	public init(
		timestamp: Date,
		operation: Operation,
		sessionID: String?,
		golden: String? = nil,
		kind: GuestKind? = nil,
		command: String? = nil,
		force: Bool? = nil,
		segments: [Segment],
		total: Duration,
		outcome: Outcome,
		state: SessionState? = nil,
		exitCode: Int32? = nil
	) {
		self.timestamp = timestamp
		self.operation = operation
		self.sessionID = sessionID
		self.golden = golden
		self.kind = kind
		self.command = command
		self.force = force
		self.segments = segments
		self.total = total
		self.outcome = outcome
		self.state = state
		self.exitCode = exitCode
	}
}

/// 單行純文字形：`key=value` 以單一空白分隔，每個操作的欄位集合與順序固定，不適用或未達的
/// 欄印 `-`；自由文字只允許出現在最後的 `error=` 欄。固定欄位刻意不帶 guest 的 hostname、
/// SSH 帳號、IP、clone host 路徑、命令輸出與完整 argv（`command` 只取 argv[0]），且外來字串
/// 一律經消毒——一事件一行是這個格式唯一的硬約束。
///
/// - Warning: `error=` 消毒截斷後透出既有的錯誤訊息，而底層失敗訊息可能夾帶主機資訊（ssh 連不上
///   會帶 guest IP 與帳號、clone 失敗會帶 host 路徑）。那些訊息本來就會經 socket 回給請求端，
///   這裡只是多了一個讀者；把 stderr 導向共用收集面之前要意識到這件事。
extension SessionLogEvent: CustomStringConvertible {

	/// 一筆事件的單行內容（不含結尾換行——換行由寫出端自己補）。
	public var description: String {
		var columns: [String] = [
			"ts=" + SessionLogEvent.renderTimestamp(timestamp),
			"op=" + operation.rawValue,
			"id=" + SessionLogEvent.renderValue(sessionID)
		]
		switch operation {
		case .spawn:
			columns.append("golden=" + SessionLogEvent.renderValue(golden))
			columns.append("kind=" + (kind?.rawValue ?? SessionLogEvent.unavailable))
			columns.append("provision=" + renderSegment(.provision))
			columns.append("start=" + renderSegment(.start))
			columns.append("ready=" + renderSegment(.ready))
			columns.append("total=" + SessionLogEvent.renderDuration(total))
			columns.append("result=" + renderedResult)
			columns.append("state=" + (state?.rawValue ?? SessionLogEvent.unavailable))

		case .execute:
			columns.append("command=" + SessionLogEvent.renderValue(command))
			columns.append("exec=" + renderSegment(.exec))
			columns.append("total=" + SessionLogEvent.renderDuration(total))
			columns.append("result=" + renderedResult)
			columns.append("exit=" + (exitCode.map { String($0) } ?? SessionLogEvent.unavailable))

		case .status:
			columns.append("total=" + SessionLogEvent.renderDuration(total))
			columns.append("result=" + renderedResult)
			columns.append("state=" + (state?.rawValue ?? SessionLogEvent.unavailable))

		case .destroy:
			columns.append("force=" + (force.map { String($0) } ?? SessionLogEvent.unavailable))
			columns.append("stop=" + renderSegment(.stop))
			columns.append("total=" + SessionLogEvent.renderDuration(total))
			columns.append("result=" + renderedResult)
		}
		if case let .error(error) = outcome {
			columns.append("error=" + error.code + ": " + SessionLogEvent.renderDetail(error.message))
		}
		return SessionLogEvent.prefix + columns.joined(separator: " ")
	}

	/// 行首標記——與 daemon 其他 stderr 訊息同一個 `nymph: ` 前綴，方便一起 grep。
	private static let prefix: String = "nymph: session "

	/// 不適用或未達之欄的佔位字元。
	private static let unavailable: String = "-"

	/// 時間戳格式：UTC、毫秒、`Z` 結尾。
	private static let timestampStyle: Date.ISO8601FormatStyle = .init(includingFractionalSeconds: true)

	/// 上限——`golden` 與 `command` 這類外來字串的截斷長度。
	private static let valueLimit: Int = 64

	/// 上限——錯誤訊息的截斷長度。
	private static let detailLimit: Int = 200

	/// `result=` 欄。
	private var renderedResult: String {
		switch outcome {
		case .ok:
			"ok"

		case .error:
			"error"
		}
	}

	/// 取某一段的耗時欄；該段未達（失敗或不適用）即印佔位字元。
	private func renderSegment(_ name: Segment.Name) -> String {
		guard let segment: Segment = segments.first(where: { $0.name == name }) else { return SessionLogEvent.unavailable }
		return SessionLogEvent.renderDuration(segment.duration)
	}

	/// 時間戳。
	private static func renderTimestamp(_ timestamp: Date) -> String {
		timestampStyle.format(timestamp)
	}

	/// 耗時：秒、三位小數、無條件捨去、尾綴 `s`。捨去而非四捨五入——log 是拿來比大小的，
	/// 進位會讓「剛好沒到」的段看起來達標。
	private static func renderDuration(_ duration: Duration) -> String {
		let parts: (seconds: Int64, attoseconds: Int64) = duration.components
		let milliseconds: Int64 = parts.attoseconds / 1_000_000_000_000_000
		return String(format: "%lld.%03llds", parts.seconds, milliseconds)
	}

	/// 需要被換掉的字元：空白（含換行與 tab）與控制字元。前者會撐破以空白分欄的格式；後者更
	/// 陰險——ESC 之類的序列會被終端解譯成游標指令，讓落檔的紀錄在 `cat` 之下看起來像是另一
	/// 行合法紀錄。兩類都不該原樣進欄。
	private static func isUnsafe(_ character: Character) -> Bool {
		character.isWhitespace || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
	}

	/// 外來字串欄（`golden`／`command`／`id`）：不安全字元換成 `_`、過長截斷。
	private static func renderValue(_ value: String?) -> String {
		guard
			let value,
			!value.isEmpty
		else { return unavailable }
		let escaped: String = String(value.map { isUnsafe($0) ? "_" : $0 })
		return escaped.count > valueLimit ? String(escaped.prefix(valueLimit)) : escaped
	}

	/// 錯誤訊息欄：不安全字元壓成空白、連續空白收成一個、過長截斷並標省略號——一事件一行
	/// 是這個格式唯一的硬約束。
	private static func renderDetail(_ detail: String) -> String {
		let flattened: String = String(detail.map { isUnsafe($0) ? " " : $0 })
		var compact: String = ""
		var previousWasSpace: Bool = false
		for character in flattened {
			if character == " " {
				if previousWasSpace {
					continue
				}
				previousWasSpace = true
			} else {
				previousWasSpace = false
			}
			compact.append(character)
		}
		return compact.count > detailLimit ? String(compact.prefix(detailLimit)) + "…" : compact
	}
}
