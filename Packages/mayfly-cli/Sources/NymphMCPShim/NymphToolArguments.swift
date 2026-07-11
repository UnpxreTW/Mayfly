//
//  NymphMCPShim
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import MCP

/// 把 MCP `CallTool.Parameters.arguments`（`[String: Value]?`、寬鬆 JSON）讀成契約 #31 五工具
/// 期待的型別欄位——集中一處，讓 ``NymphToolInvoker`` 的五個 build 函式只管欄位名稱、不重複
/// 寫 optional-unwrap 樣板。找不到 / 型別不合一律回預設值或 nil，**必填欄位缺失**由呼叫端
/// 另以 `requiredString(_:)` 擲 ``NymphShimError/missingArgument(_:)``（映成 tool-error、不是
/// MCP 協議層錯誤——argv 打錯字不該讓 shim 崩）。
struct NymphToolArguments {

	/// - Parameter raw: `CallTool.Parameters.arguments`；nil 視同空表。
	init(_ raw: [String: Value]?) {
		self.raw = raw ?? [:]
	}

	/// 必填字串；缺失或空字串擲 ``NymphShimError/missingArgument(_:)``。
	func requiredString(_ key: String) throws -> String {
		guard let value = raw[key]?.stringValue, !value.isEmpty else {
			throw NymphShimError.missingArgument(key)
		}
		return value
	}

	/// 選填字串；缺失回 nil。
	func string(_ key: String) -> String? {
		raw[key]?.stringValue
	}

	/// 選填整數；缺失（或 `null`）回 `defaultValue`。以 swift-sdk 寬鬆轉型接受字串編碼的整數
	/// （`"8"` → 8）；**存在但無法轉成整數**（`"abc"`、陣列、非整數 double 等）擲
	/// ``NymphShimError/invalidArgument(_:)``——不靜默吞成預設（明示值被無聲忽略是 bug）。
	func int(_ key: String, default defaultValue: Int) throws -> Int {
		guard let value = raw[key], !value.isNull else {
			return defaultValue
		}
		guard let converted = Int(value, strict: false) else {
			throw NymphShimError.invalidArgument(key)
		}
		return converted
	}

	/// 選填整數；缺失（或 `null`）回 nil（用於 `timeout_s` 這類「未設＝不設限」的欄位、與「有預設值」
	/// 的欄位區分）。**存在但無法轉成整數**擲 ``NymphShimError/invalidArgument(_:)``（同
	/// ``int(_:default:)`` 的寬鬆轉型與嚴格失敗）。
	func optionalInt(_ key: String) throws -> Int? {
		guard let value = raw[key], !value.isNull else {
			return nil
		}
		guard let converted = Int(value, strict: false) else {
			throw NymphShimError.invalidArgument(key)
		}
		return converted
	}

	/// 選填布林；缺失（或 `null`）回 `defaultValue`。以 swift-sdk 寬鬆轉型接受字串編碼的布林
	/// （`"false"` → false）；**存在但無法轉成布林**擲 ``NymphShimError/invalidArgument(_:)``——
	/// 不靜默吞成預設。
	func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
		guard let value = raw[key], !value.isNull else {
			return defaultValue
		}
		guard let converted = Bool(value, strict: false) else {
			throw NymphShimError.invalidArgument(key)
		}
		return converted
	}

	/// 必填字串陣列（非空）；缺失、非陣列或空陣列擲 ``NymphShimError/missingArgument(_:)``
	/// （`execute` 的 `cmd`——空命令送進 daemon 沒有意義）；陣列**任一元素非字串**擲
	/// ``NymphShimError/invalidArgument(_:)``——不 `compactMap` 靜默丟棄非字串元素（那會無聲改寫
	/// argv，把 `["swift", 42]` 縮成 `["swift"]`）。
	func requiredStringArray(_ key: String) throws -> [String] {
		guard let array = raw[key]?.arrayValue, !array.isEmpty else {
			throw NymphShimError.missingArgument(key)
		}
		var strings: [String] = []
		strings.reserveCapacity(array.count)
		for element in array {
			guard let string = element.stringValue else {
				throw NymphShimError.invalidArgument(key)
			}
			strings.append(string)
		}
		return strings
	}

	/// 選填字串字典（`execute` 的 `env`）；缺失或型別不合回空表。
	func stringDictionary(_ key: String) -> [String: String] {
		guard let object = raw[key]?.objectValue else {
			return [:]
		}
		var result: [String: String] = [:]
		for (fieldKey, fieldValue) in object {
			if let string = fieldValue.stringValue {
				result[fieldKey] = string
			}
		}
		return result
	}

	private let raw: [String: Value]
}

/// shim 層的參數驗證失敗——與契約 #31 的引擎 ``NymphError`` 分開（那是 daemon 內部失敗，這是
/// 「argv 送進 shim 前就不合規」），但同樣映成 MCP tool-error（`isError: true`）、不是協議層
/// 錯誤或行程崩潰。
enum NymphShimError: Error {

	/// 缺少必填參數（帶欄位名）。
	case missingArgument(String)

	/// 參數存在但型別不合規（帶欄位名）——與「缺失」區分：明示了值、但值不是期待的型別
	/// （如 `cmd` 陣列含非字串元素、`memory_gib` 是無法解析成整數的字串）。
	case invalidArgument(String)

	/// `spawn` 的 `golden` 是 `/` 開頭絕對路徑——MCP 邊界（不可信呼叫端）只收 golden root 下的
	/// 具名 alias；``GoldenResolver`` 的絕對路徑逃生梯（#33 NY-3）留給受信任的 daemon socket
	/// 直連方（CLI 等），不對 MCP 開放。
	case invalidGoldenAlias

	/// 對外穩定碼。
	var code: String {
		switch self {
		case .missingArgument, .invalidArgument, .invalidGoldenAlias:
			return "invalid_arguments"
		}
	}

	/// 人讀訊息——只含公開 schema 的欄位名、不含任何 host 內部資訊（含呼叫端送來的字串值：即使
	/// 值是 client 自己送的、不算新洩漏，仍維持「shim 對外訊息一律通稱化」的紀律）。
	var message: String {
		switch self {
		case let .missingArgument(field):
			return "missing or invalid required argument: \(field)"

		case let .invalidArgument(field):
			return "argument has an invalid type: \(field)"

		case .invalidGoldenAlias:
			return "golden must be a named alias, not a host path"
		}
	}
}
