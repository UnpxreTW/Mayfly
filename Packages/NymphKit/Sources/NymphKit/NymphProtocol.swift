//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// nymph daemon 的**我方自訂 socket 協議**（非 MCP——MCP 面是步③的薄 stdio shim、
/// 橋接到本協議）。單一連線走 newline-delimited JSON：一行一個 ``NymphRequest`` / 一行
/// 一個 ``NymphResponse``（`JSONEncoder` 對字串內換行轉義成 `\n`、payload 保證單行、換行
/// 分幀安全）。CLI / app（現在）與 stdio shim（步③）皆為 client、共用這組型別。
///
/// enum + associated value 的 `Codable` 走編譯器合成（兩端皆本模組、格式穩定即可）；
/// round-trip 由 `NymphProtocolTests` 鎖住。

/// client → daemon 的請求。動詞集對映契約 #31 的五工具。
public enum NymphRequest: Codable, Sendable, Equatable {

	/// clone + boot + 等 READY（依 NY-1 阻塞 / 逾時降級）。
	case spawn(SpawnParams)

	/// 在既有 session 內執行命令（SSH、經 ``MacGuestExec``）。
	case execute(ExecuteParams)

	/// 列出 session。
	case list(ListParams)

	/// 查單一 session 狀態。
	case status(StatusParams)

	/// 停 VM + 刪 clone + 移出 table。
	case destroy(DestroyParams)
}

/// daemon → client 的回應。成功回對應結果、失敗回 ``ToolError``（tool-error envelope）。
public enum NymphResponse: Codable, Sendable, Equatable {

	/// spawn 成功。
	case spawn(SpawnResult)

	/// execute 成功（`exit` 是資料、非零不是 tool-error）。
	case execute(ExecuteResult)

	/// list 成功。
	case list(ListResult)

	/// status 成功。
	case status(StatusResult)

	/// destroy 成功。
	case destroy(DestroyResult)

	/// 工具錯誤（no such id / 未 ready / 傳輸失敗 / 達上限…）。
	case toolError(ToolError)
}

/// spawn 參數（契約 #31：`golden` 是別名、非 host 路徑，daemon 解析）。
public struct SpawnParams: Codable, Sendable, Equatable {

	/// golden 別名。
	public let golden: String

	/// 要開的 guest 種類；必填、無預設，缺欄即解碼失敗。
	public let os: GuestKind

	/// 要求 vCPU 數（引擎收斂到 host 上限）。
	public let cpus: Int

	/// 要求記憶體（GiB、引擎收斂）。
	public let memoryGiB: Int

	/// 是否阻塞到 READY（NY-1 預設 true；逾時降級 booting 不自殺）。
	public let wait: Bool

	/// readiness 等待上限（秒）。
	public let readinessTimeoutSeconds: Int

	public init(
		golden: String,
		os: GuestKind,
		cpus: Int = 4,
		memoryGiB: Int = 4,
		wait: Bool = true,
		readinessTimeoutSeconds: Int = 180
	) {
		self.golden = golden
		self.os = os
		self.cpus = cpus
		self.memoryGiB = memoryGiB
		self.wait = wait
		self.readinessTimeoutSeconds = readinessTimeoutSeconds
	}
}

/// execute 參數。
public struct ExecuteParams: Codable, Sendable, Equatable {

	/// 目標 session 的 opaque id。
	public let id: String

	/// 遠端命令 argv（非空）。
	public let command: [String]

	/// 整體逾時（秒）；nil＝不設限。
	public let timeoutSeconds: Int?

	/// 餵給遠端 stdin 的文字；nil＝無輸入。
	public let standardInput: String?

	/// 遠端執行前 `cd` 的目錄；nil＝登入預設目錄。
	public let workingDirectory: String?

	/// 額外環境變數（走 `env K=V`）。
	public let environment: [String: String]

	public init(
		id: String,
		command: [String],
		timeoutSeconds: Int? = nil,
		standardInput: String? = nil,
		workingDirectory: String? = nil,
		environment: [String: String] = [:]
	) {
		self.id = id
		self.command = command
		self.timeoutSeconds = timeoutSeconds
		self.standardInput = standardInput
		self.workingDirectory = workingDirectory
		self.environment = environment
	}
}

/// list 參數。
public struct ListParams: Codable, Sendable, Equatable {

	/// true 含已 stopped 未回收者；預設只列活的。
	public let all: Bool

	public init(all: Bool = false) {
		self.all = all
	}
}

/// status 參數。
public struct StatusParams: Codable, Sendable, Equatable {

	/// 目標 session id。
	public let id: String

	public init(id: String) {
		self.id = id
	}
}

/// destroy 參數。
public struct DestroyParams: Codable, Sendable, Equatable {

	/// 目標 session id。
	public let id: String

	/// true → forceStop；false → ensureStopped(within: grace)。預設 true。
	public let force: Bool

	public init(id: String, force: Bool = true) {
		self.id = id
		self.force = force
	}
}

/// spawn 結果（不漏 host 路徑）。
public struct SpawnResult: Codable, Sendable, Equatable {

	/// opaque handle（`mfly-xxxxxxxx`）。
	public let id: String

	/// 收斂後狀態，由控制面回報（`ready`、或逾時降級的 `booting`）；guest 於等待期間停止時
	/// 亦可能為 `stopped`。
	public let state: SessionState

	/// guest IP；未解出時為 nil——含尚在 booting、以及沒接網路的 guest（此時仍可能是 `ready`）。
	public let ip: String?

	public init(id: String, state: SessionState, ip: String?) {
		self.id = id
		self.state = state
		self.ip = ip
	}
}

/// execute 結果（`exit` 是遠端命令真實退出碼、資料）。
public struct ExecuteResult: Codable, Sendable, Equatable {

	/// 標準輸出。
	public let standardOutput: String

	/// 標準錯誤。
	public let standardError: String

	/// 結束碼。
	public let exit: Int32

	public init(standardOutput: String, standardError: String, exit: Int32) {
		self.standardOutput = standardOutput
		self.standardError = standardError
		self.exit = exit
	}
}

/// 單一 session 的對外摘要（不含 host 路徑）。
public struct SessionSummary: Codable, Sendable, Equatable {

	/// opaque id。
	public let id: String

	/// 狀態。
	public let state: SessionState

	/// IP（未解出為 nil）。
	public let ip: String?

	/// golden 別名（回傳用、非 host 路徑）。
	public let golden: String

	/// vCPU 數。
	public let cpus: Int

	/// 記憶體（GiB）。
	public let memoryGiB: Int

	/// 存活秒數。
	public let uptimeSeconds: Int

	public init(
		id: String,
		state: SessionState,
		ip: String?,
		golden: String,
		cpus: Int,
		memoryGiB: Int,
		uptimeSeconds: Int
	) {
		self.id = id
		self.state = state
		self.ip = ip
		self.golden = golden
		self.cpus = cpus
		self.memoryGiB = memoryGiB
		self.uptimeSeconds = uptimeSeconds
	}
}

/// list 結果。
public struct ListResult: Codable, Sendable, Equatable {

	/// session 摘要清單（空表為正常）。
	public let sessions: [SessionSummary]

	public init(sessions: [SessionSummary]) {
		self.sessions = sessions
	}
}

/// status 結果（在摘要之上多帶 stop_reason）。
public struct StatusResult: Codable, Sendable, Equatable {

	/// session 摘要。
	public let summary: SessionSummary

	/// 停止原因（`guest` / `error` / `forced`）；未停為 nil。
	public let stopReason: String?

	public init(summary: SessionSummary, stopReason: String? = nil) {
		self.summary = summary
		self.stopReason = stopReason
	}
}

/// destroy 結果。
public struct DestroyResult: Codable, Sendable, Equatable {

	/// 被銷毀的 id。
	public let id: String

	/// 恆 true（no-such-id 走 ``ToolError``、不走此結果）。
	public let destroyed: Bool

	public init(id: String, destroyed: Bool = true) {
		self.id = id
		self.destroyed = destroyed
	}
}

/// 對外 tool-error envelope：穩定的 `code`（供程式判別）＋人讀 `message`。由 ``NymphError``
/// 於協議邊界映成。
public struct ToolError: Codable, Sendable, Equatable, Error {

	/// 穩定錯誤碼（如 `no_such_id`、`transport_failure`）。
	public let code: String

	/// 人讀訊息。
	public let message: String

	public init(code: String, message: String) {
		self.code = code
		self.message = message
	}

	/// 把內部 ``NymphError`` 映成對外 envelope——code 穩定、message 帶脈絡。
	public init(_ error: NymphError) {
		switch error {
		case let .noSuchID(id):
			self.init(code: "no_such_id", message: "no such session id: \(id)")

		case let .admissionDenied(limit):
			self.init(code: "admission_denied", message: "concurrent session limit reached (\(limit))")

		case let .goldenNotFound(alias):
			self.init(code: "golden_not_found", message: "golden alias not found: \(alias)")

		case let .cloneFailed(detail):
			self.init(code: "clone_failed", message: "clone failed: \(detail)")

		case .notReady:
			self.init(code: "not_ready", message: "session is not ready")

		case .ipUnavailable:
			self.init(code: "ip_unavailable", message: "session is ready but no IP is resolvable yet")

		case let .transportFailure(detail):
			self.init(code: "transport_failure", message: "ssh transport failure: \(detail)")

		case .execTimedOut:
			self.init(code: "timed_out", message: "execute timed out")

		case .notAppleSilicon:
			self.init(code: "not_apple_silicon", message: "nymph requires Apple Silicon")

		case let .engineUnavailable(kind):
			self.init(code: "engine_unavailable", message: "no engine is registered for guest kind: \(kind.rawValue)")

		case let .internalFailure(detail):
			self.init(code: "internal_error", message: detail)
		}
	}
}
