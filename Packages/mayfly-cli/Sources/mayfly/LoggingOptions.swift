//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import Logging

/// 每支子命令共用的紀錄門檻選項。
///
/// 門檻在 ``validate()`` 決定——ArgumentParser 對子命令自己與其 `@OptionGroup` 都會在
/// `run()` 之前呼叫一次，所以第一行紀錄送出時門檻必定已就位。解析只此一處：旗標優先於
/// `LOG_LEVEL` 環境變數，兩者都沒有就是 `info`。
///
/// - Note: 為什麼不在進入點掃 argv 決定門檻——`execute` 的遠端命令是 passthrough 捕獲的，
///   `mayfly execute <id> foo --log-level bar` 裡那個 token 屬於遠端命令、不屬於這支 CLI；
///   只有解析器分得清這件事。
internal struct LoggingOptions: ParsableArguments {

	/// 紀錄門檻；未給就看 `LOG_LEVEL`。宣告成 optional 才分得出「沒給」與「給了預設值」，
	/// 代價是 `--help` 不會自動印預設值 ⇒ 說明文字自己寫。
	@Option(
		name: .customLong("log-level"),
		help: "Minimum log level (default: info, or the LOG_LEVEL environment variable)."
	)
	internal var logLevel: LogLevelArgument?

	/// 供 ArgumentParser 建構。
	internal init() {}

	/// 把解析結果套進這個行程的紀錄門檻。
	internal func validate() throws {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: logLevel,
			environment: ProcessInfo.processInfo.environment
		)
		CommandOutput.setLogLevel(resolved.level)
		if let warning: String = resolved.warning {
			CommandOutput.logger.warning("\(warning)")
		}
	}

	/// 由旗標與環境決定門檻——純函式，不讀行程狀態、不寫任何東西。
	///
	/// 環境變數是備援、不是輸入驗證面：值不認得時不擲錯（那會讓一個打錯字的環境變數擋掉整支
	/// 命令），改落回 `info` 並回一句待送出的提醒。
	///
	/// - Parameters:
	///   - flag: `--log-level` 給的值；未給為 nil。
	///   - environment: 行程環境。
	/// - Returns: 門檻，以及需要提醒時的那句話。
	internal static func resolve(
		flag: LogLevelArgument?,
		environment: [String: String]
	) -> (level: Logger.Level, warning: String?) {
		if let flag: LogLevelArgument {
			return (flag.level, nil)
		}
		guard
			let raw: String = environment[LoggingOptions.environmentKey],
			!raw.isEmpty
		else { return (.info, nil) }
		guard let parsed: LogLevelArgument = .init(rawValue: raw.lowercased()) else {
			let quoted: String = LoggingOptions.sanitize(raw)
			return (.info, "LOG_LEVEL=\(quoted) is not a log level; using info")
		}
		return (parsed.level, nil)
	}

	/// 備援門檻的環境變數名。
	private static let environmentKey: String = "LOG_LEVEL"

	/// 提醒句裡的環境變數值上限。
	private static let valueLimit: Int = 32

	/// 外來字串進紀錄行之前的消毒：非英數一律換成 `_`、過長截斷。
	///
	/// 換行與 ESC 之類的字元原樣寫出去，會讓一個打錯的環境變數在落檔的紀錄裡看起來像另一行
	/// 合法紀錄。
	///
	/// - Parameter value: 原值。
	/// - Returns: 可安全放進單行紀錄的字串。
	private static func sanitize(_ value: String) -> String {
		String(value.prefix(valueLimit).map { $0.isLetter || $0.isNumber ? $0 : "_" })
	}
}
