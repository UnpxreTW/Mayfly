//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization

// 本身符號（VZVirtualMachine / VZNetworkDevice）雙 arch 都有、不需 gate；
// 但它是 ``MacGuest`` 專屬的內部 delegate proxy，隨 MacGuest 一起 arch-gate
// ——x86_64 上沒 MacGuest、留個沒人用的 internal class 無意義。
#if arch(arm64)

/// `VZVirtualMachineDelegate` 的接收端：把落在 vmQueue 上的 callback 轉譯
/// 成 Sendable 事件外送、並收斂停機狀態。
///
/// 刻意**不標 Sendable**：出生與被呼叫都只在 vmQueue 上，讓編譯器替我們
/// 守「不得跨界傳遞」；可變狀態（waiters / stopReason）全靠該 queue 序列化。
final class GuestEventRelay: NSObject, VZVirtualMachineDelegate {

	init(queue: DispatchQueue, eventContinuation: AsyncStream<GuestEvent>.Continuation) {
		self.queue = queue
		self.eventContinuation = eventContinuation
	}

	deinit {
		// 不收尾的話消費者的 for-await 會在 MacGuest 釋放後永久懸掛。
		// Continuation 自身 Sendable、finish() 可在任意 thread 呼叫——
		// deinit 不碰 vm、不違反 vmQueue 不變式。
		eventContinuation.finish()
	}

	/// 等停止的 waiter 們；vmQueue 保護。
	var stopWaiters: [UUID: CheckedContinuation<GuestStopReason, any Error>] = [:]

	/// 取消搶先於註冊的 tombstone；vmQueue 保護。
	var cancelledWaiterIDs: Set<UUID> = []

	/// 第一個停機原因；settle 後不再覆寫。vmQueue 保護。
	private(set) var stopReason: GuestStopReason?

	/// 收斂停機：發事件（`event` 給 nil 表示 host 硬停、無對應 delegate
	/// 事件）、記第一個 reason、喚醒並清空所有 waiter。
	func settle(reason: GuestStopReason, event: GuestEvent?) {
		dispatchPrecondition(condition: .onQueue(queue))
		if let event {
			eventContinuation.yield(event)
		}
		guard stopReason == nil else {
			return
		}
		stopReason = reason
		for waiter in stopWaiters.values {
			waiter.resume(returning: reason)
		}
		stopWaiters.removeAll()
	}

	func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		settle(reason: .guestInitiated, event: .guestDidStop)
	}

	func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
		settle(reason: .error(error), event: .stoppedWithError(error))
	}

	func virtualMachine(
		_ virtualMachine: VZVirtualMachine,
		networkDevice: VZNetworkDevice,
		attachmentWasDisconnectedWithError error: any Error
	) {
		dispatchPrecondition(condition: .onQueue(queue))
		eventContinuation.yield(.networkAttachmentDisconnected(error))
	}

	/// 防衛用：斷言 callback 確實落在綁定 queue 上。
	private let queue: DispatchQueue

	/// 事件流出口（自身 Sendable、可安全跨界）。
	private let eventContinuation: AsyncStream<GuestEvent>.Continuation
}

#endif
