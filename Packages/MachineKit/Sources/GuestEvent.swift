//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// guest 生命週期事件——delegate callback 的 Sendable 轉譯，經
/// ``MacGuest/events`` 外送。
public enum GuestEvent: Sendable {

	/// guest 自行關機完成。唯一可靠的退出信號。
	case guestDidStop

	/// VM 因內部錯誤停止。error 原樣保留、不在 library 層吞掉。
	case stoppedWithError(any Error)

	/// 網路附掛斷線。開機 / 重開機過程可能多次出現；**不是**退出信號，
	/// 與停機事件分開列舉以保留語意。
	case networkAttachmentDisconnected(any Error)
}
