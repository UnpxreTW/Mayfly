//
//  mayflyTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging
import Testing

@testable import mayfly

// MARK: - LoggingOptionsTests

private final class LoggingOptionsTests {

	/// 兩處都沒說話就是 `info`。
	@Test
	private func `neither flag nor environment falls back to info`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(flag: nil, environment: [:])
		#expect(resolved.level == .info)
		#expect(resolved.warning == nil)
	}

	/// 只有環境變數時照它。
	@Test
	private func `environment sets the level`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: nil,
			environment: ["LOG_LEVEL": "debug"]
		)
		#expect(resolved.level == .debug)
		#expect(resolved.warning == nil)
	}

	/// 環境變數大小寫不計較——`LOG_LEVEL` 常常是人手打進 plist 或 shell 的。
	@Test
	private func `environment value is case insensitive`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: nil,
			environment: ["LOG_LEVEL": "TRACE"]
		)
		#expect(resolved.level == .trace)
	}

	/// 旗標勝過環境變數。
	@Test
	private func `flag wins over environment`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: .error,
			environment: ["LOG_LEVEL": "critical"]
		)
		#expect(resolved.level == .error)
		#expect(resolved.warning == nil)
	}

	/// 空字串等同沒設——`LOG_LEVEL=` 不該被當成打錯字。
	@Test
	private func `empty environment value is treated as unset`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: nil,
			environment: ["LOG_LEVEL": ""]
		)
		#expect(resolved.level == .info)
		#expect(resolved.warning == nil)
	}

	/// 認不得的環境變數值不擲錯：落回 `info`、附一句提醒。
	@Test
	private func `unknown environment value falls back to info with a warning`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: nil,
			environment: ["LOG_LEVEL": "verbose"]
		)
		#expect(resolved.level == .info)
		#expect(resolved.warning == "LOG_LEVEL=verbose is not a log level; using info")
	}

	/// 提醒句裡的外來值經消毒：換行與控制字元不得原樣進單行紀錄。
	@Test
	private func `warning sanitises the offending value`() {
		let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
			flag: nil,
			environment: ["LOG_LEVEL": "info\nerror mayfly: forged"]
		)
		#expect(resolved.level == .info)
		#expect(resolved.warning?.contains("\n") == false)
		#expect(resolved.warning == "LOG_LEVEL=info_error_mayfly__forged is not a log level; using info")
	}

	/// 每個可選值都對得上同名的 `Logger.Level`。
	@Test
	private func `every argument value maps to the level of the same name`() {
		for argument in LogLevelArgument.allCases {
			#expect(argument.level.rawValue == argument.rawValue)
		}
	}
}
