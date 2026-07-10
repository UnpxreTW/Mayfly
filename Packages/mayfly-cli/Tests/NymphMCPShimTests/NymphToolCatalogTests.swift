//
//  NymphMCPShimTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import NymphMCPShim

// MARK: - NymphToolCatalogTests

private final class NymphToolCatalogTests {

	/// 五工具、契約 #31 順序、名稱對映 ``NymphRequest`` case（`execute` / `list`，非 CLI 別名
	/// `exec` / `ps`）。
	@Test
	private func `catalog exposes exactly the five contract tools in order`() {
		let names: [String] = NymphToolCatalog.tools.map(\.name)
		#expect(names == ["spawn", "execute", "list", "status", "destroy"])
	}

	/// 每個工具都有非空描述——`tools/list` 給 LLM 讀，缺描述等於沒有 schema。
	@Test
	private func `every tool has a non empty description`() {
		for tool in NymphToolCatalog.tools {
			#expect((tool.description ?? "").isEmpty == false)
		}
	}

	/// 必填欄位對映契約 #31：spawn 只要 golden；execute 要 id + cmd；status/destroy 只要 id。
	@Test
	private func `required fields match contract 31`() {
		let required: [String: [String]] = Dictionary(
			uniqueKeysWithValues: NymphToolCatalog.tools.map { ($0.name, $0.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
		)
		#expect(required["spawn"] == ["golden"])
		#expect(required["execute"] == ["id", "cmd"])
		#expect(required["list"] == [])
		#expect(required["status"] == ["id"])
		#expect(required["destroy"] == ["id"])
	}

	/// round-trip：`ListTools.Result` 過一趨 encode/decode 後，工具名稱與必填欄位不失真——
	/// 這是 shim 實際會送上線的 JSON 形狀（`Server.send` 用同一個 `JSONEncoder`）。
	@Test
	private func `list tools result round trips through JSON`() throws {
		let result: ListTools.Result = .init(tools: NymphToolCatalog.tools)
		let encoder: JSONEncoder = .init()
		let data: Data = try encoder.encode(result)
		let decoded: ListTools.Result = try JSONDecoder().decode(ListTools.Result.self, from: data)
		#expect(decoded.tools.map(\.name) == result.tools.map(\.name))
		for (original, decoded) in zip(result.tools, decoded.tools) {
			#expect(original.inputSchema == decoded.inputSchema)
		}
	}
}
