//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// ``MacGuestSession`` 的失敗情形。
public enum MacGuestSessionError: Error, Equatable {

	/// ``MacGuestSession/start()`` 已呼叫過（含失敗的那次）。session 與 ``MacGuest``
	/// 同為一次性生命週期：start 失敗即棄、另 clone 一份再建 session。
	case alreadyStarted

	/// 尚未 ``MacGuestSession/start()`` 就呼叫了需要活 guest 的操作。
	case notStarted
}
