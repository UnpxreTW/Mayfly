//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 跑一個外部命令、回 stdout（非零 exit 擲 ``GuestVolumeMounterError/commandFailed(executable:status:stderr:)``）。
///
/// 抽成 protocol 是為了讓 ``GuestVolumeMounter`` 的**命令構造與輸出解析可單測**——
/// 測試注入假 runner、驗「下了什麼 hdiutil / diskutil 指令、拿到的 plist 怎麼解」，
/// 完全不必真跑外部工具或碰真磁碟。真實作見 ``SystemCommandRunner``。
public protocol CommandRunner: Sendable {

	/// 跑 `executable` 帶 `arguments`，回 stdout bytes；非零 exit 擲錯（帶 stderr）。
	func run(executable: String, arguments: [String]) async throws -> Data
}
