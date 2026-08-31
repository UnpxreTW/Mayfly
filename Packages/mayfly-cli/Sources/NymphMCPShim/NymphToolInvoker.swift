//
//  NymphMCPShim
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import NymphKit

/// 把一個 `CallTool.Parameters` 分派成 `CallTool.Result`——薄殼紀律：真正的編排在 daemon 的
/// `SessionStore`，這層只做 MCP 參數 ↔ ``NymphRequest`` ↔ ``NymphResponse`` ↔ MCP 結果的轉接
/// （鏡射 CLI 的 `NymphClientSupport`，換一種傳輸面）。
///
/// 錯誤語義對齊契約 #31：daemon 的 tool-error（``ToolError``）、shim 自己的參數驗證失敗
/// （``NymphShimError``）、與連不上 daemon 的傳輸失敗（``NymphTransportError``）三者**都**映成
/// `CallTool.Result(isError: true)`——不擲協議層錯誤、不讓 argv 打錯字或 daemon 未起崩掉 shim
/// 行程。唯一不算 tool-error 的是**遠端命令非零 exit**（`execute` 的 `exit` 欄位是資料）。
enum NymphToolInvoker {

	/// 已知工具名——與 ``NymphToolCatalog`` 及 ``NymphRequest`` 的 case 一一對映（`execute` /
	/// `list` 是契約 #31 定名，非 CLI 別名 `exec` / `ps`）。
	private enum ToolName: String {
		case spawn
		case execute
		case list
		case status
		case destroy
	}

	/// 分派入口：`NymphMCPServer` 的 `CallTool` handler 直接呼叫此函式。
	static func handle(_ params: CallTool.Parameters, client: NymphClient) async -> CallTool.Result {
		guard let tool = ToolName(rawValue: params.name) else {
			return errorResult(code: "unknown_tool", message: "unknown tool: \(params.name)")
		}
		let arguments: NymphToolArguments = .init(params.arguments)
		do {
			let request: NymphRequest = try buildRequest(tool, arguments: arguments)
			let response: NymphResponse = try await client.send(request)
			return map(response)
		} catch let error as NymphShimError {
			return errorResult(code: error.code, message: error.message)
		} catch let error as NymphTransportError {
			return errorResult(code: "daemon_unreachable", message: transportErrorMessage(for: error))
		} catch {
			return errorResult(code: "internal_error", message: "an internal shim error occurred")
		}
	}

	// MARK: - request building

	private static func buildRequest(_ tool: ToolName, arguments: NymphToolArguments) throws -> NymphRequest {
		switch tool {
		case .spawn:
			let golden: String = try arguments.requiredString("golden")
			// MCP 邊界視為不可信呼叫端：golden 只收 golden root 下的具名 alias，擋
			// ``GoldenResolver`` 的 `/` 開頭絕對路徑逃生梯（#33 NY-3）——逃生梯留給受信任的
			// daemon socket 直連方（CLI 等），不對 MCP 開放。
			guard !golden.hasPrefix("/") else {
				throw NymphShimError.invalidGoldenAlias
			}
			let osRaw: String = try arguments.requiredString("os")
			guard let os: GuestKind = .init(rawValue: osRaw) else { throw NymphShimError.invalidGuestKind }
			return .spawn(SpawnParams(
				golden: golden,
				os: os,
				cpus: try arguments.int("cpus", default: 4),
				memoryGiB: try arguments.int("memory_gib", default: 4),
				wait: try arguments.bool("wait", default: true),
				readinessTimeoutSeconds: try arguments.int("readiness_timeout_s", default: 180)
			))

		case .execute:
			return .execute(ExecuteParams(
				id: try arguments.requiredString("id"),
				command: try arguments.requiredStringArray("cmd"),
				timeoutSeconds: try arguments.optionalInt("timeout_s"),
				standardInput: arguments.string("stdin"),
				workingDirectory: arguments.string("cwd"),
				environment: arguments.stringDictionary("env")
			))

		case .list:
			return .list(ListParams(all: try arguments.bool("all", default: false)))

		case .status:
			return .status(StatusParams(id: try arguments.requiredString("id")))

		case .destroy:
			return .destroy(DestroyParams(
				id: try arguments.requiredString("id"),
				force: try arguments.bool("force", default: true)
			))
		}
	}

	// MARK: - response mapping

	private static func map(_ response: NymphResponse) -> CallTool.Result {
		switch response {
		case let .spawn(result):
			return successResult(spawnValue(result))

		case let .execute(result):
			return successResult(executeValue(result))

		case let .list(result):
			return successResult(listValue(result))

		case let .status(result):
			return successResult(statusValue(result))

		case let .destroy(result):
			return successResult(destroyValue(result))

		case let .toolError(error):
			return errorResult(code: error.code, message: daemonErrorMessage(for: error.code))
		}
	}

	// MARK: - outward error genericisation

	/// daemon ``ToolError`` 的對外訊息：**只依穩定 `code` 給通稱化訊息、丟棄 daemon 原始
	/// `message`**。daemon 訊息可能夾帶 host 絕對路徑（`clone_failed` 帶 `clone failed: <path>`）、
	/// guest IP／ssh stderr／known_hosts（`transport_failure`）、或 `String(describing:)` 內部細節
	/// （`internal_error`）——這些留在 daemon 自己的 host-side log，不外流給 MCP client。LLM 拿到
	/// actionable 的 `code` 已足夠判斷下一步。未知／未來新增的 code 落 `default` 的通稱訊息、
	/// 不外流。
	private static func daemonErrorMessage(for code: String) -> String {
		switch code {
		case "no_such_id":
			return "no session with the requested id"

		case "admission_denied":
			return "the concurrent session limit has been reached"

		case "golden_not_found":
			return "the requested golden alias was not found"

		case "clone_failed":
			return "failed to clone the golden bundle"

		case "not_ready":
			return "the session is not ready"

		case "ip_unavailable":
			return "the session is ready but no IP is resolvable yet"

		case "transport_failure":
			return "the SSH connection to the guest failed"

		case "timed_out":
			return "the operation timed out"

		case "not_apple_silicon":
			return "nymph requires Apple Silicon"

		case "bad_request":
			return "the request was malformed"

		case "internal_error":
			return "the nymph daemon reported an internal error"

		default:
			return "the nymph daemon reported an error"
		}
	}

	/// 傳輸失敗的對外訊息：**去掉 path／errno**。``NymphTransportError/description`` 帶 socket
	/// 路徑（`pathTooLong`）與 errno 供 host-side triage／CLI（host 使用者看自機路徑無妨），但
	/// MCP client 不該看到 host 檔案系統路徑——只給通稱化的 per-case 訊息，不帶任何值。
	private static func transportErrorMessage(for error: NymphTransportError) -> String {
		switch error {
		case .connectFailed:
			return "cannot reach the nymph daemon (is `mayfly nymph` running?)"

		case .connectionClosed:
			return "the connection to the nymph daemon closed before a response arrived"

		case .pathTooLong:
			return "the nymph socket path is too long"

		case .socketCreationFailed:
			return "failed to create the nymph socket"

		case .bindFailed:
			return "failed to bind the nymph socket"

		case .listenFailed:
			return "failed to listen on the nymph socket"
		}
	}

	/// 契約 #31 的 spawn 回傳形狀：`{ id, state, ip }`。
	private static func spawnValue(_ result: SpawnResult) -> Value {
		[
			"id": .string(result.id),
			"state": .string(result.state.rawValue),
			"ip": result.ip.map(Value.string) ?? .null,
		]
	}

	/// 契約 #31 的 execute 回傳形狀：`{ stdout, stderr, exit }`（`exit` 是資料）。
	private static func executeValue(_ result: ExecuteResult) -> Value {
		[
			"stdout": .string(result.standardOutput),
			"stderr": .string(result.standardError),
			"exit": .int(Int(result.exit)),
		]
	}

	/// 契約 #31 的 list 回傳形狀：`{ sessions: [...] }`（不含 host 路徑）。
	private static func listValue(_ result: ListResult) -> Value {
		["sessions": .array(result.sessions.map { .object(sessionSummaryFields($0)) })]
	}

	/// 契約 #31 的 status 回傳形狀：摘要欄位 + `stop_reason`。
	private static func statusValue(_ result: StatusResult) -> Value {
		var fields: [String: Value] = sessionSummaryFields(result.summary)
		fields["stop_reason"] = result.stopReason.map(Value.string) ?? .null
		return .object(fields)
	}

	/// 契約 #31 的 destroy 回傳形狀：`{ id, destroyed }`。
	private static func destroyValue(_ result: DestroyResult) -> Value {
		[
			"id": .string(result.id),
			"destroyed": .bool(result.destroyed),
		]
	}

	/// `list` / `status` 共用的單一 session 摘要形狀：`{ id, state, ip, golden, cpus,
	/// memory_gib, uptime_s }`（`golden` 經 ``outwardGoldenValue(_:)`` 通稱化）。
	private static func sessionSummaryFields(_ summary: SessionSummary) -> [String: Value] {
		[
			"id": .string(summary.id),
			"state": .string(summary.state.rawValue),
			"ip": summary.ip.map(Value.string) ?? .null,
			"golden": .string(outwardGoldenValue(summary.golden)),
			"cpus": .int(summary.cpus),
			"memory_gib": .int(summary.memoryGiB),
			"uptime_s": .int(summary.uptimeSeconds),
		]
	}

	/// `golden` 欄位的對外值：具名 alias 原樣；`/` 開頭（受信任的 daemon socket 直連方以絕對
	/// 路徑逃生梯 spawn 的 session、見 #33 NY-3）換成固定通稱字串。daemon socket 是跨管道
	/// 共用的——直連方與 MCP shim 談同一張 session table，session 不保證源自 MCP、host 路徑
	/// 不因來源不同而外流；縱深防禦，不依賴「兩者不共用 daemon」的部署拓樸保證。
	private static func outwardGoldenValue(_ golden: String) -> String {
		golden.hasPrefix("/") ? "<external-path>" : golden
	}

	// MARK: - result envelopes

	/// 成功結果：`content` 帶人讀 JSON 文字、`structuredContent` 帶同一份 `Value`（機器可讀）。
	///
	/// - `Value?` 局部變數是必要的、不是多餘：`CallTool.Result` 有一個非 optional generic
	///   `Codable` overload（`structuredContent: Output`），直接傳 `Value`（本身即 `Codable`）
	///   會撞上那個 overload、變成 throws 呼叫；先鑄型成 `Value?` 逼編譯器選對非 throws 的
	///   overload。
	private static func successResult(_ value: Value) -> CallTool.Result {
		let structuredContent: Value? = value
		return .init(content: [.text(text: jsonText(value), annotations: nil, _meta: nil)], structuredContent: structuredContent, isError: false)
	}

	/// tool-error 結果——涵蓋契約 #31 的 daemon `ToolError`、shim 參數驗證失敗、與傳輸失敗三種
	/// 來源，統一 `{ code, message }` 形狀（`code` 供程式判別、`message` 供人讀）。
	private static func errorResult(code: String, message: String) -> CallTool.Result {
		let value: Value = ["code": .string(code), "message": .string(message)]
		let structuredContent: Value? = value
		return .init(content: [.text(text: "error [\(code)]: \(message)", annotations: nil, _meta: nil)], structuredContent: structuredContent, isError: true)
	}

	/// `Value` → 緊湊 JSON 文字（sorted keys，供 `content` 的人讀文字塊與測試斷言）。
	private static func jsonText(_ value: Value) -> String {
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
			return "{}"
		}
		return text
	}
}
