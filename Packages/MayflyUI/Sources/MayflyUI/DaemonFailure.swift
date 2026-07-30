//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// 一次 daemon 往返失敗的對外形狀——畫面只認這四態，傳輸層與協議層的細節不外漏。
public enum DaemonFailure: Error, Equatable, Sendable {

	/// 連線從未建立：daemon 沒在跑、app 找的落點不是它綁的那個，或這個落點根本連不成
	/// （路徑超過 `sun_path` 上限、建不出 socket）。`detail` 帶傳輸層的原因，後者才有。
	case unreachable(endpoint: DaemonEndpoint, detail: String?)

	/// 連線建立**之後**才出事：回應沒讀完就斷。**與 `unreachable` 分開**——這一態代表那頭
	/// 確實有東西接了連線，指向的是 daemon 的問題、不是找錯落點。
	case interrupted(detail: String)

	/// daemon 收下請求但回報工具錯誤（`code` 穩定、可供程式判別）。
	case tool(code: String, message: String)

	/// 回應解不開或動詞對不上——協議版本落差。
	case protocolMismatch

	/// 把往返擲出的錯誤收斂成四態。
	///
	/// - Parameters:
	///   - error: 往返過程擲出的錯誤。
	///   - endpoint: 本次往返使用的端點快照，供 ``guidance`` 說明實際探過哪個落點。
	public init(mapping error: any Error, endpoint: DaemonEndpoint) {
		switch error {
		case let toolError as ToolError:
			self = .tool(code: toolError.code, message: toolError.message)

		case let transport as NymphTransportError:
			// 只有「連上之後才斷」算 interrupted。其餘傳輸錯誤都還沒接上——連 socket 路徑
			// 過長與建不出 socket 都發生在 connect 之前，講成連線中斷會把設定問題導向
			// 「daemon 掛了」；但那兩種的原因是可行動的，帶著走、別只留通則說明。
			// 六個 case 列全、不留 `default`：日後 NymphKit 補一個「連線之後」才發生的傳輸
			// 錯誤時，這裡會編譯失敗、逼出一次明確裁決，而不是靜默貼上「連線建立不起來」。
			switch transport {
			case .connectionClosed:
				self = .interrupted(detail: transport.description)

			case .connectFailed:
				self = .unreachable(endpoint: endpoint, detail: nil)

			case .pathTooLong, .socketCreationFailed, .bindFailed, .listenFailed:
				self = .unreachable(endpoint: endpoint, detail: transport.description)
			}

		default:
			self = .protocolMismatch
		}
	}

	/// 一行標題（畫面主標）。
	var headline: String {
		switch self {
		case .unreachable:
			return "連不上 daemon"

		case .interrupted:
			return "與 daemon 的連線中斷"

		case .tool:
			return "daemon 回報錯誤"

		case .protocolMismatch:
			return "daemon 的回應無法解讀"
		}
	}

	/// 補充說明——`unreachable` 的三款措辭刻意分開：傳輸層講得出原因時**先講原因**（路徑過長
	/// 之類是設定問題、不是 daemon 問題）；講不出時才退到落點事實，而**socket 檔不存在不等於
	/// 沒有 daemon 在跑**——由 Finder／Dock 啟動的 app 繼承的是 launchd 環境、讀不到 shell
	/// 匯出的 state dir 覆寫，這裡只能誠實說出「探過哪個落點」，不假裝已經找遍。
	var guidance: String {
		switch self {
		case let .unreachable(_, detail?):
			return "連線建立不起來：\(detail)"

		case let .unreachable(endpoint, _) where endpoint.isSocketPresent:
			return "socket 檔在 \(endpoint.socketPath)，但連不上：daemon 可能已結束、只留下殘檔。"

		case let .unreachable(endpoint, _):
			return "\(endpoint.socketPath) 沒有 socket。由 Finder／Dock 啟動的 app 讀不到 shell "
				+ "匯出的 \(NymphPaths.stateDirectoryEnvironmentKey)，所以這只代表預設落點沒有 socket，"
				+ "不代表沒有 daemon 在跑。"

		case let .interrupted(detail):
			return "連線建立後沒有完成往返：\(detail)"

		case let .tool(code, message):
			return "[\(code)] \(message)"

		case .protocolMismatch:
			return "daemon 的版本可能與這個 app 不一致。"
		}
	}
}
