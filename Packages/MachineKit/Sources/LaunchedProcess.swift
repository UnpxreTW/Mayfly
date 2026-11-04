//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``ProcessLauncher/launch(executable:arguments:standardInput:standardOutput:standardError:)``
/// 啟動後的行程。
public protocol LaunchedProcess: Sendable {

	/// 等行程結束、且 stdout / stderr 都讀到 EOF，回結束碼。可重複呼叫、結束後立即回。
	func waitForExit() async -> Int32

	/// 送 SIGTERM；行程已結束則不做事。
	func terminate()
}
