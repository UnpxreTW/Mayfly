//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MachineKit

// MARK: - GuestExecution

/// ``GuestControl/startExec(_:standardInput:workingDirectory:environment:standardOutput:standardError:)``
/// 啟動後的命令：等待（可設上限）或取消。真機即 `MacGuestExecHandle`；測試以 fake 取代。
public protocol GuestExecution: Sendable {

	/// 等命令結束，回終局。
	/// - Parameter timeout: 等待上限；nil＝不設限。到時走終止流程、回 `.timedOut`。
	/// - Returns: 終局；可重複呼叫，結束後回同一個值。
	func wait(timeout: Duration?) async -> MacGuestExecOutcome

	/// 取消：走終止流程。命令已結束則不做事。
	func cancel() async
}
