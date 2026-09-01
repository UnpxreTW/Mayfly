//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 跑一個外部命令、回 stdout（非零 exit 擲 ``CommandRunnerError/commandFailed(executable:status:stderr:)``）。
///
/// 抽成 protocol 是為了讓 ``MacGuestVolumeMounter`` 的**命令構造與輸出解析可單測**——
/// 測試注入假 runner、驗「下了什麼 hdiutil / diskutil 指令、拿到的 plist 怎麼解」，
/// 完全不必真跑外部工具或碰真磁碟。真實作見 ``SystemCommandRunner``。
public protocol CommandRunner: Sendable {

	/// 跑 `executable` 帶 `arguments`，回 stdout bytes；非零 exit 擲
	/// ``CommandRunnerError/commandFailed(executable:status:stderr:)``（帶 stderr）。
	func run(executable: String, arguments: [String]) async throws -> Data
}

/// ``CommandRunner`` 的執行失敗。
///
/// 錯誤契約屬於執行器本身、**不掛任一呼叫端的錯誤型別**：runner 是共用抽象，任何
/// consumer 都能接；把它的失敗表成某個 consumer 的 enum，等於逼其他 consumer 去
/// catch 一個與自己無關的層。呼叫端要自有語義就在自己那層轉譯（見
/// ``MacGuestVolumeMounter``）。
public enum CommandRunnerError: Error, Equatable, Sendable {

	/// 外部命令非零 exit；帶結束碼與 stderr 供呼叫端判讀（如 busy / locked 這類可重試
	/// 或需轉語義的情況）。
	case commandFailed(executable: String, status: Int32, stderr: String)
}
