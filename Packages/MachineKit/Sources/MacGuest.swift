//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization

// VZVirtualMachine 本身雙 arch 都有符號，但 init 路徑經 builder 觸碰
// VZMac*（SDK header 被 `#ifdef __arm64__` 包住、x86_64 無符號）——整檔
// 隨 builder 一起以 arch 條件編譯隔離；Intel host 上套件只剩 Host、
// MacGuestSpec 與 KeychainPreflight。
#if arch(arm64)

// MARK: - GuestEvent

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

// MARK: - GuestStopReason

/// guest 停止的原因。
public enum GuestStopReason: Sendable {

	/// guest 自行關機（guestDidStop）。
	case guestInitiated

	/// VM 因錯誤停止（didStopWithError）。
	case error(any Error)

	/// 因 ``MacGuest/forceStop()`` 或 ``MacGuest/ensureStopped(within:)``
	/// 的逾時 fallback 而硬停；等待中的 ``MacGuest/waitUntilStopped()``
	/// 也會以此收斂返回。
	case forced
}

// MARK: - MacGuestError

/// harness 層錯誤。VZ 層失敗除 keychain 診斷命中外原樣上拋 `VZError`。
public enum MacGuestError: Error {

	/// preflight：login keychain 鎖定。macOS 15+ host 上 `start()` 會以
	/// 無線索的通用 Code=1 失敗，所以在碰 VZ 之前先擋下、給可修復的錯誤。
	case keychainLocked(path: String?)

	/// preflight：無 default keychain。
	case noDefaultKeychain

	/// `start()` 已失敗（`VZErrorDomain` Code=1）且二次診斷發現 keychain
	/// 此刻不可用——把通用 internal error 翻成可修復的錯誤；underlying
	/// 保留原始 `VZError` 供上層記錄。
	case startBlockedByKeychain(underlying: any Error, keychain: KeychainPreflight.Status)
}

// MARK: - MacGuest

/// 一台 macOS guest 的生命週期 harness：把非 thread-safe 的
/// `VZVirtualMachine` 困在一條私有 serial queue 上，對外只露 async 門面
/// 與 Sendable 事件。
///
/// `@unchecked Sendable` 不變式：`vm` 與 `relay` 只在 `vmQueue` 上觸碰——
/// 這正是 Virtualization 的 queue 合約（init 即綁定該 queue、callback 與
/// delegate 落在其上、非 serial queue 上未定義）；本標註只是把這份
/// runtime 合約對型別系統做的免責聲明。佐證：(1) 兩者在 `queue.sync` 內
/// 出生、sync 邊界順帶提供 safe publication；(2) 每個 public 入口第一步
/// 就 hop 到 vmQueue；(3) 跨界外送的東西（continuation）自身 Sendable；
/// (4) delegate callback 以 `dispatchPrecondition` 防衛。
///
/// 絕不暴露 `VZVirtualMachine` 本體：編譯器不會替呼叫端擋「非對齊
/// executor 上裸 `await vm.start()`」，queue 紀律只能靠 API 形狀強制。
/// 同理 MachineKit 不綁 process runloop——那是 CLI / App 層的選擇。
///
/// 一台 `MacGuest` 是**一次性生命週期**：停止後不支援重啟（停機狀態
/// 一經收斂即黏死）、要再開機請另建一台。釋放前先確保 guest 已停
/// （``ensureStopped(within:)``）——running 中釋放屬無文件保證的灰色地帶。
public final class MacGuest: @unchecked Sendable {

	// MARK: Public

	/// builder Console 的轉出口，讓呼叫端不必直接碰 builder 命名空間。
	public typealias Console = MacGuestConfigurationBuilder.Console

	/// 生命週期事件流。單一消費者語意：多處 for-await 會分食事件。事件
	/// yield 自 vmQueue、消費發生在呼叫端自己的 Task 上。注意 host 硬停
	/// （``forceStop()``）沒有對應的 delegate callback、不會出現在本流——
	/// 停機的單一真相是 ``waitUntilStopped()``。
	public let events: AsyncStream<GuestEvent>

	/// 啟動 guest。
	///
	/// macOS 15+ host 先跑 ``KeychainPreflight``：鎖定 / 缺失即擲
	/// ``MacGuestError``、完全不碰 VZ（14- host 鎖定 keychain 不影響 VZ、
	/// 不誤殺；`undetermined` 放行——偵測器自己壞不該擋路）。`start()`
	/// 失敗且為通用 Code=1 時重跑 preflight 做二次診斷（不分版本）：
	/// keychain 不可用 → 擲
	/// ``MacGuestError/startBlockedByKeychain(underlying:keychain:)``、
	/// 否則原樣上拋。再深入的診斷看 unified log（library 不代跑、只給
	/// 指引）：`log show --last 2m --predicate 'subsystem == "com.apple.security"'`
	/// 配合 Virtualization helper 行程過濾。
	public func start() async throws {
		if #available(macOS 15, *) {
			switch KeychainPreflight.status() {
			case let .locked(path):
				throw MacGuestError.keychainLocked(path: path)
			case .missing:
				throw MacGuestError.noDefaultKeychain
			case .unlocked, .undetermined:
				break
			}
		}
		do {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
				vmQueue.async {
					self.vm.start { result in
						continuation.resume(with: result)
					}
				}
			}
		} catch let error as VZError where error.code == .internalError {
			// 顯式寫全名：省略型別會被 formatter 的 propertyTypes 規則
			// 誤判（status() 回傳 Status、不是 KeychainPreflight 自身）。
			let keychain: KeychainPreflight.Status = KeychainPreflight.status()
			switch keychain {
			case .locked, .missing:
				throw MacGuestError.startBlockedByKeychain(underlying: error, keychain: keychain)
			case .unlocked, .undetermined:
				throw error
			}
		}
	}

	/// host 硬停（destructive、guest 無清理機會）。正常拆除順序是 guest
	/// 內關機（呼叫端 SSH `sudo shutdown -h now`）+
	/// ``ensureStopped(within:)``；這是它的逾時 fallback、也是不得已時的
	/// 最後手段。
	public func forceStop() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			vmQueue.async {
				self.vm.stop { error in
					if let error {
						continuation.resume(throwing: error)
					} else {
						// host 硬停不會收到 guestDidStop——在這裡收斂，
						// 讓 pending waiter 與事件流不被晾著。
						self.relay.settle(reason: .forced, event: nil)
						continuation.resume()
					}
				}
			}
		}
	}

	/// 等 guest 停止。已停止則立即返回（不漏接「開始等之前就停了」）；
	/// guest 永不停止則本方法永不返回——要逾時兜底用
	/// ``ensureStopped(within:)``、或以 Task 取消逃生。唯一的 throw 是
	/// Task 取消（`CancellationError`）——non-throwing 版本在取消時沒有
	/// 誠實的值可回。
	public func waitUntilStopped() async throws -> GuestStopReason {
		let id: UUID = .init()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestStopReason, any Error>) in
				vmQueue.async {
					// onCancel 可能搶在註冊前跑（tombstone 已放）——兩個
					// 閉包都在 vmQueue 上序列化、無 race；先消化 tombstone
					// 確保它不殘留，取消也優先於「已停止」的值。
					if self.relay.cancelledWaiterIDs.remove(id) != nil {
						continuation.resume(throwing: CancellationError())
						return
					}
					if let reason = self.relay.stopReason {
						continuation.resume(returning: reason)
						return
					}
					self.relay.stopWaiters[id] = continuation
				}
			}
		} onCancel: {
			vmQueue.async {
				if let waiter = self.relay.stopWaiters.removeValue(forKey: id) {
					waiter.resume(throwing: CancellationError())
				} else if self.relay.stopReason == nil {
					// 已 settle 就不插 tombstone：operation 會以快路徑收
					// 斂回值（cooperative cancellation 容許）、插了沒人清。
					self.relay.cancelledWaiterIDs.insert(id)
				}
			}
		}
	}

	/// 等 guest 自行停止、逾時 fallback 硬 stop()。
	///
	/// fallback 與 guest 自行關機賽跑時 stop() 可能以 invalid state 系
	/// 錯誤失敗——不視為失敗、以 guest 實際停止狀態收斂回報；真的還沒
	/// 停才上拋。呼叫端負責先從 guest 內驅動關機；本方法只負責等與兜底。
	/// Task 取消擲 `CancellationError`、**不會**觸發硬停——取消不是逾時、
	/// 不該把等待升級成毀滅性動作。
	public func ensureStopped(within gracePeriod: Duration) async throws -> GuestStopReason {
		let raced = await withTaskGroup(of: GuestStopReason?.self) { group in
			group.addTask { try? await self.waitUntilStopped() }
			group.addTask {
				try? await Task.sleep(for: gracePeriod)
				return nil
			}
			defer { group.cancelAll() }
			return await group.next() ?? nil
		}
		if let reason = raced {
			return reason
		}
		// race 回 nil 有兩種可能：真逾時、或本 Task 被取消（兩個 child 的
		// 錯誤都被 try? 吸掉）——先分流，取消絕不 fallback 硬停。
		try Task.checkCancellation()
		do {
			try await forceStop()
			// stop() 發起後、完成前 guest 恰好自停的極窄窗：settle 不會
			// 覆寫先到的 reason——回實際收斂值、與其他 waiter 一致。
			return await settledStopReason() ?? .forced
		} catch {
			// stop() 失敗的瞬間 guest 可能恰好自停（race）——回報實際
			// 停止原因；真的沒停才把 stop 的錯誤上拋。
			if let reason = await settledStopReason() {
				return reason
			}
			throw error
		}
	}

	/// 目前 VM 狀態（hop 到 vmQueue 讀取後送回）。刻意不提供同步
	/// getter——`queue.sync` 會堵 cooperative pool 的執行緒、且留下死鎖
	/// 路徑。
	public func currentState() async -> VZVirtualMachine.State {
		await withCheckedContinuation { continuation in
			vmQueue.async {
				continuation.resume(returning: self.vm.state)
			}
		}
	}

	/// 在 vmQueue 上把 spec 翻成 configuration 並建構 VM（delegate 也在
	/// 同 queue 上設定）。spec 層錯誤擲 `MacGuestConfigurationError`、VZ
	/// 層原樣擲 `VZError`。
	public init(spec: MacGuestSpec, console: Console? = nil) throws {
		let queue: DispatchQueue = .init(label: "MachineKit.MacGuest")
		let (stream, continuation) = AsyncStream.makeStream(of: GuestEvent.self)
		self.vmQueue = queue
		self.events = stream
		// sync 閉包保證建構與 delegate 設定發生在 vmQueue 上（VZ 的 queue
		// 合約含 init）；之後的可見性由 dispatch 入隊邊界 + self 完成初始
		// 化才可能跨界保證。閉包捕局部值、不捕尚未初始化完的 self。
		(self.vm, self.relay) = try queue.sync {
			let configuration = try MacGuestConfigurationBuilder.makeConfiguration(from: spec, console: console)
			let machine: VZVirtualMachine = .init(configuration: configuration, queue: queue)
			let proxy: GuestEventRelay = .init(queue: queue, eventContinuation: continuation)
			machine.delegate = proxy
			return (machine, proxy)
		}
	}

	// MARK: Private

	/// 一切 VZ 觸碰的唯一入口；`vm` / `relay` 的隔離邊界。
	private let vmQueue: DispatchQueue

	/// 被駕馭的 VM 本體。只在 `vmQueue` 上觸碰、絕不外露。
	private let vm: VZVirtualMachine

	/// delegate proxy。`vm.delegate` 是 weak、由 harness 強持有。
	private let relay: GuestEventRelay

	/// 讀 relay 的已停狀態（vmQueue 上）；未停回 nil。
	private func settledStopReason() async -> GuestStopReason? {
		await withCheckedContinuation { continuation in
			vmQueue.async {
				continuation.resume(returning: self.relay.stopReason)
			}
		}
	}
}

// MARK: - GuestEventRelay

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
