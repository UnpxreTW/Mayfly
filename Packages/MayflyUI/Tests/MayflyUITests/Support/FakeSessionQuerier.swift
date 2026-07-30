//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

@testable import MayflyUI

/// 可控時序的 ``SessionQuerying`` 替身。
///
/// 每個呼叫都有一個標籤（`list#1`、`status#1:mfly-a`）：`gate(_:)` 讓該呼叫停在回傳前、
/// `waitForCall(_:)` 等它真的抵達、`openGate(_:)` 放它走——陳舊回應的測試因此靠事件排序，
/// 不靠睡眠猜時間。
///
/// 標籤一律帶該目標的呼叫序號（`list#N`＝第 N 次 list、`status#N:<id>`＝該 id 的第 N 次）：
/// 同一個目標被查兩次時才不會共用一個等待槽（覆蓋掉的 continuation 永遠不會被 resume，
/// 測試會變成卡死而不是紅字）。
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
		gateWaiters.removeValue(forKey: label)?.resume()
	}

	/// 等標籤對應的呼叫真的抵達。
	func waitForCall(_ label: String) async {
		guard !arrivedLabels.contains(label) else {
			return
		}
		await withCheckedContinuation { continuation in
			arrivalWaiters[label] = continuation
		}
	}

	// MARK: Private

	private var listResults: [Result<ListResult, any Error>]

	private var statusResults: [String: Result<StatusResult, any Error>] = [:]

	private var gatedLabels: Set<String> = []

	private var openedLabels: Set<String> = []

	private var arrivedLabels: Set<String> = []

	private var gateWaiters: [String: CheckedContinuation<Void, Never>] = [:]

	private var arrivalWaiters: [String: CheckedContinuation<Void, Never>] = [:]

	private func nextListResult() -> Result<ListResult, any Error> {
		guard listResults.count > 1 else {
			return listResults[0]
		}
		return listResults.removeFirst()
	}

	private func noteArrival(_ label: String) {
		arrivedLabels.insert(label)
		arrivalWaiters.removeValue(forKey: label)?.resume()
	}

	private func waitIfGated(_ label: String) async {
		guard gatedLabels.contains(label), !openedLabels.contains(label) else {
			return
		}
		await withCheckedContinuation { continuation in
			gateWaiters[label] = continuation
		}
	}
}
