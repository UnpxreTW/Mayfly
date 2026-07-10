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
			return errorResult(code: "daemon_unreachable", message: error.description)
		} catch {
			return errorResult(code: "internal_error", message: "\(error)")
		}
	}

	// MARK: - request building

	private static func buildRequest(_ tool: ToolName, arguments: NymphToolArguments) throws -> NymphRequest {
		switch tool {
		case .spawn:
			return .spawn(SpawnParams(
				golden: try arguments.requiredString("golden"),
				cpus: arguments.int("cpus", default: 4),
				memoryGiB: arguments.int("memory_gib", default: 4),
				wait: arguments.bool("wait", default: true),
				readinessTimeoutSeconds: arguments.int("readiness_timeout_s", default: 180)
			))

		case .execute:
			return .execute(ExecuteParams(
				id: try arguments.requiredString("id"),
				command: try arguments.requiredStringArray("cmd"),
				timeoutSeconds: arguments.optionalInt("timeout_s"),
				standardInput: arguments.string("stdin"),
				workingDirectory: arguments.string("cwd"),
				environment: arguments.stringDictionary("env")
			))

		case .list:
			return .list(ListParams(all: arguments.bool("all", default: false)))

		case .status:
			return .status(StatusParams(id: try arguments.requiredString("id")))

		case .destroy:
			return .destroy(DestroyParams(
				id: try arguments.requiredString("id"),
				force: arguments.bool("force", default: true)
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
			return errorResult(code: error.code, message: error.message)
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
	/// memory_gib, uptime_s }`。
	private static func sessionSummaryFields(_ summary: SessionSummary) -> [String: Value] {
		[
			"id": .string(summary.id),
			"state": .string(summary.state.rawValue),
			"ip": summary.ip.map(Value.string) ?? .null,
			"golden": .string(summary.golden),
			"cpus": .int(summary.cpus),
			"memory_gib": .int(summary.memoryGiB),
			"uptime_s": .int(summary.uptimeSeconds),
		]
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
