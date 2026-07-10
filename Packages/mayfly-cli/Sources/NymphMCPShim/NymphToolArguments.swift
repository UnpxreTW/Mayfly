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

	/// 選填整數；缺失或型別不合回 `defaultValue`。
	func int(_ key: String, default defaultValue: Int) -> Int {
		raw[key]?.intValue ?? defaultValue
	}

	/// 選填整數；缺失回 nil（用於 `timeout_s` 這類「未設＝不設限」的欄位、與「有預設值」的欄位區分）。
	func optionalInt(_ key: String) -> Int? {
		raw[key]?.intValue
	}

	/// 選填布林；缺失或型別不合回 `defaultValue`。
	func bool(_ key: String, default defaultValue: Bool) -> Bool {
		raw[key]?.boolValue ?? defaultValue
	}

	/// 必填字串陣列（非空）；缺失、型別不合或空陣列擲 ``NymphShimError/missingArgument(_:)``
	/// （`execute` 的 `cmd`——空命令送進 daemon 沒有意義）。
	func requiredStringArray(_ key: String) throws -> [String] {
		guard let values = raw[key]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty else {
			throw NymphShimError.missingArgument(key)
		}
		return values
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

	/// 對外穩定碼。
	var code: String {
		switch self {
		case .missingArgument:
			return "invalid_arguments"
		}
	}

	/// 人讀訊息。
	var message: String {
		switch self {
		case let .missingArgument(field):
			return "missing or invalid required argument: \(field)"
		}
	}
}
