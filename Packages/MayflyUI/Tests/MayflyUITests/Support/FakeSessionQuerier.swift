//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

@testable import MayflyUI

/// 可控時序的 ``SessionQuerying`` 替身。
///
/// 每個呼叫都有一個標籤（`list#1`、`status#1:mfly-a`）：`gate(_:)` 讓該呼叫停在回傳前、
/// `waitForCall(_:)` 等它真的抵達、`openGate(_:)` 放它走——陳舊回應的測試因此靠事件排序，
/// 不靠睡眠猜時間。
///
/// **兩側的等待都有上限**（等抵達、等放行），逾時即記 issue：標籤打錯時要得到紅字與診斷，
/// 而不是掛住整個測試行程。
///
/// 標籤一律帶該目標的呼叫序號（`list#N`＝第 N 次 list、`status#N:<id>`＝該 id 的第 N 次）：
/// 同一個目標被查兩次時才不會共用一個閘門（`openGate` 放行的會是錯的那一次）。
actor FakeSessionQuerier: SessionQuerying {

	// MARK: Internal

	/// - Parameter list: 第一筆 list 回應；之後的以 ``enqueueList(_:)`` 追加，最後一筆會被重複使用。
	init(list: Result<ListResult, any Error> = .success(ListResult(sessions: []))) {
		listResults = [list]
	}

	/// 每次 list 呼叫收到的 `includeStopped`（依序）。
	private(set) var listCalls: [Bool] = []

	/// 每次 status 呼叫的目標 id（依序）。
	private(set) var statusCalls: [String] = []

	func listSessions(includeStopped: Bool) async throws -> ListResult {
		listCalls.append(includeStopped)
		let label: String = "list#\(listCalls.count)"
		// 回應在進場即取定：閘門只延後回傳時點，不改變哪一筆回應屬於哪一次呼叫。
		let result: Result<ListResult, any Error> = nextListResult()
		noteArrival(label)
		await waitIfGated(label)
		return try result.get()
	}

	func sessionStatus(id: String) async throws -> StatusResult {
		statusCalls.append(id)
		// 序號是「這個 id 的第幾次」而非全域計數——標籤要讓人算得出來，算錯的下場是靜默
		// 不生效或永遠等不到，兩者都是卡死而不是紅字。
		let label: String = "status#\(statusCalls.filter { $0 == id }.count):\(id)"
		// 與 list 側同理：回應在進場即取定，閘門只延後回傳時點。
		let result: Result<StatusResult, any Error>? = statusResults[id]
		noteArrival(label)
		await waitIfGated(label)
		guard let result else {
			throw UnexpectedDaemonResponse()
		}
		return try result.get()
	}

	/// 追加一筆 list 回應。
	func enqueueList(_ result: Result<ListResult, any Error>) {
		listResults.append(result)
	}

	/// 設定某個 id 的 status 回應。
	func setStatus(id: String, _ result: Result<StatusResult, any Error>) {
		statusResults[id] = result
	}

	/// 讓標籤對應的呼叫停在回傳前。
	func gate(_ label: String) {
		gatedLabels.insert(label)
	}

	/// 放行停在閘門前的呼叫（先開後到也算數）。
	func openGate(_ label: String) {
		openedLabels.insert(label)
	}

	/// 等標籤對應的呼叫真的抵達；最多等 `timeout`，逾時就記一條 issue 並返回。
	///
	/// **等待一定要有上限**：被等的呼叫若因回歸而永遠不來，無上限的等待會掛住整個測試行程，
	/// CI 拿到的是 job timeout 而不是紅字。`.timeLimit` trait 救不了這種等待——實測它會在時限
	/// 到時記下 issue，但停在非取消感知的等待上的測試仍不會結束。
	func waitForCall(_ label: String, timeout: Duration = .seconds(5)) async {
		guard !arrivedLabels.contains(label) else {
			return
		}
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: timeout)
		// 短間隔重查而非 continuation：actor 內把 continuation 與逾時做成競速，稍有不慎就
		// double-resume 而當場崩潰；這裡粒度與上限都看得見，代價只是每毫秒醒一次。
		while clock.now < deadline {
			if arrivedLabels.contains(label) {
				return
			}
			try? await Task.sleep(for: .milliseconds(1))
			if Task.isCancelled {
				break
			}
		}
		if !arrivedLabels.contains(label) {
			Issue.record("等不到呼叫 \(label)（已等 \(timeout)）；已抵達的有 \(arrivedLabels.sorted())")
		}
	}

	// MARK: Private

	private var listResults: [Result<ListResult, any Error>]

	private var statusResults: [String: Result<StatusResult, any Error>] = [:]

	private var gatedLabels: Set<String> = []

	private var openedLabels: Set<String> = []

	private var arrivedLabels: Set<String> = []

	private func nextListResult() -> Result<ListResult, any Error> {
		guard listResults.count > 1 else {
			return listResults[0]
		}
		return listResults.removeFirst()
	}

	private func noteArrival(_ label: String) {
		arrivedLabels.insert(label)
	}

	/// 停在閘門前直到被放行；最多等 `timeout`，逾時記一條 issue 後**自行放行**。
	///
	/// 與 ``waitForCall(_:timeout:)`` 同一個理由：`openGate` 的標籤打錯一個字，無上限的等待
	/// 就會掛住整個測試行程。這裡逾時後放它走，測試才會走到斷言、拿到紅字與診斷訊息。
	private func waitIfGated(_ label: String, timeout: Duration = .seconds(5)) async {
		guard gatedLabels.contains(label), !openedLabels.contains(label) else {
			return
		}
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: timeout)
		while clock.now < deadline {
			if openedLabels.contains(label) {
				return
			}
			try? await Task.sleep(for: .milliseconds(1))
			if Task.isCancelled {
				break
			}
		}
		if !openedLabels.contains(label) {
			Issue.record("閘門 \(label) 沒有被放行（已等 \(timeout)）；已放行的有 \(openedLabels.sorted())")
		}
	}
}
