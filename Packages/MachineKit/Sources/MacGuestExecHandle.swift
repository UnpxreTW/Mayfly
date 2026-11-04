//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``MacGuestExec/start(_:onHost:standardInput:workingDirectory:environment:standardOutput:standardError:)``
/// 啟動後的命令：等待（可設上限）或取消。
///
/// 逾時與取消走同一條終止流程：先另開一趟 ssh 對 guest 內的行程群組送訊號（整棵行程樹），
/// 再對本機的 ssh 客戶端送 SIGTERM 收尾（guest 已連不上時，至少本機這端不會留著）。
/// 終止流程只跑一次——逾時與取消同時發生時，先到的那個決定終局。
///
/// 行程結束由建構時起的內部 task 觀察，不靠呼叫端有沒有在等：命令一結束就不再接受取消，
/// 不會對已結束命令的群組送訊號、也不會蓋掉真正的結束碼。
public final class MacGuestExecHandle: @unchecked Sendable {

	// MARK: Public

	/// 等命令結束，回終局。
	///
	/// - Parameter timeout: 等待上限；nil＝不設限。到時走終止流程、回 ``MacGuestExecOutcome/timedOut``。
	///   計時器只在第一次帶上限的呼叫時起、整個 handle 只有一個；之後的上限一律不理。計時器不隨
	///   呼叫端的 task 取消而停——呼叫端被取消也不會讓命令變成沒有上限。
	/// - Returns: 終局。可重複呼叫，結束後立即回同一個值。呼叫端 task 被取消時照樣等到命令結束。
	public func wait(timeout: Duration? = nil) async -> MacGuestExecOutcome {
		if let timeout {
			armTimer(timeout)
		}
		let exitCode: Int32 = await exitTask.value
		return outcome(exitCode: exitCode)
	}

	/// 取消：走終止流程。命令已結束（或已在終止中）則不做事。
	public func cancel() async {
		await terminate(as: .cancelled)
	}

	// MARK: Internal

	/// - Parameters:
	///   - process: 本機 ssh 行程。
	///   - standardError: stderr 緩衝（傳輸失敗時取訊息用）。
	///   - terminateRemote: 對 guest 內行程群組送訊號的那一趟。
	internal init(
		process: any LaunchedProcess,
		standardError: OutputTailBuffer,
		terminateRemote: @escaping @Sendable () async -> Void
	) {
		let state: State = .init()
		self.process = process
		self.standardError = standardError
		self.terminateRemote = terminateRemote
		self.state = state
		exitTask = Task {
			let code: Int32 = await process.waitForExit()
			let timer: Task<Void, Never>? = state.withLock { value in
				value.finished = true
				return value.timer
			}
			timer?.cancel()
			return code
		}
	}

	// MARK: Private

	/// 終止流程是由誰觸發的。
	private enum Reason {

		/// 等待逾時。
		case timedOut

		/// 呼叫端取消。
		case cancelled
	}

	/// 鎖護住的可變狀態。
	private struct Fields {

		/// 終止流程的觸發者；nil＝沒走過終止流程。
		internal var reason: Reason?

		/// 命令已結束（內部 task 已拿到結束碼）。
		internal var finished: Bool = false

		/// 逾時計時器；nil＝還沒起。
		internal var timer: Task<Void, Never>?
	}

	/// ``Fields`` 的上鎖封套（建構時就要交給內部 task，故獨立成物件）。
	private final class State: @unchecked Sendable {

		/// 上鎖後對欄位做一次讀寫。
		/// - Parameter body: 讀寫欄位的區塊。
		/// - Returns: 區塊的回傳值。
		internal func withLock<Result>(_ body: (inout Fields) -> Result) -> Result {
			lock.lock()
			defer { lock.unlock() }
			return body(&fields)
		}

		/// 護住 ``fields``。
		private let lock: NSLock = .init()

		/// 鎖護住的欄位。
		private var fields: Fields = .init()
	}

	/// 本機 ssh 行程。
	private let process: any LaunchedProcess

	/// stderr 緩衝。
	private let standardError: OutputTailBuffer

	/// 對 guest 內行程群組送訊號。
	private let terminateRemote: @Sendable () async -> Void

	/// 可變狀態。
	private let state: State

	/// 觀察行程結束的內部 task，值為結束碼。
	private let exitTask: Task<Int32, Never>

	/// 起逾時計時器；已起過或命令已結束則不做事。
	private func armTimer(_ timeout: Duration) {
		state.withLock { value in
			guard
				value.timer == nil,
				!value.finished
			else { return }
			value.timer = Task { [weak self] in
				do {
					try await Task.sleep(for: timeout)
				} catch {
					return
				}
				await self?.terminate(as: .timedOut)
			}
		}
	}

	/// 走一次終止流程；已走過或命令已結束則不做事。
	private func terminate(as trigger: Reason) async {
		let first: Bool = state.withLock { value in
			guard
				value.reason == nil,
				!value.finished
			else { return false }
			value.reason = trigger
			return true
		}
		guard first else { return }
		await terminateRemote()
		process.terminate()
	}

	/// 結束碼 → 終局。走過終止流程的以觸發者為準；否則 255＝ssh 傳輸失敗、其餘是命令的結束碼。
	private func outcome(exitCode: Int32) -> MacGuestExecOutcome {
		switch state.withLock({ $0.reason }) {
		case .timedOut:
			return .timedOut
		case .cancelled:
			return .cancelled
		case nil:
			if exitCode == MacGuestExec.sshTransportFailureCode {
				return .transportFailure(standardError.snapshot().text)
			}
			return .exited(exitCode)
		}
	}
}
