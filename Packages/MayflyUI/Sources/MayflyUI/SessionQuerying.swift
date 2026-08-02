//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

// MARK: - SessionQuerying

/// GUI 側取得 session 資料的注入點——畫面只依賴這個介面，測試因此不需要真的 daemon 在跑。
///
/// 動詞刻意只收 `list` / `status` 兩個唯讀面；破壞性動詞（spawn / execute / destroy）留後續
/// 切片，屆時在同一個介面上加方法即可。
public protocol SessionQuerying: Sendable {

	/// 列出 session。
	/// - Parameter includeStopped: true 含已 stopped 未回收者。
	func listSessions(includeStopped: Bool) async throws -> ListResult

	/// 查單一 session 的狀態（比清單多帶 stop reason）。
	func sessionStatus(id: String) async throws -> StatusResult
}

// MARK: - UnexpectedDaemonResponse

/// 回應的動詞對不上請求——daemon 與 app 的協議版本有落差才會出現。
public struct UnexpectedDaemonResponse: Error, Equatable, Sendable {

	public init() {}
}

// MARK: - DaemonSessionQuerier

/// 走真實 nymph socket 的 ``SessionQuerying``：把回應的三個分支（結果／tool-error／動詞錯配）
/// 收斂成 Swift 的回傳與擲出，形狀與 CLI 端 `ListCommand` / `StatusCommand` 一致。
///
/// - Important: 往返**沒有逾時、也不可取消**（傳輸層本身不支援）。daemon 接了連線卻不回應時
///   呼叫端會一直等，而且每一次卡住的往返會佔住一條 socket I/O 佇列的執行緒直到 daemon
///   回應或行程結束——反覆重試可能把執行緒池吃光。逾時要在傳輸層做，留後續切片。
public struct DaemonSessionQuerier: SessionQuerying {

	// MARK: Public

	/// - Parameter endpoint: 目標端點；socket 路徑一律由它給。
	///
	/// - Important: 刻意**不**用 ``NymphClient/init(socketPath:)`` 的預設落點解析。那會是第二個
	///   解析點：畫面說明講的是 ``DaemonEndpoint`` 解出的落點，往返打的卻是客戶端自己解的，
	///   兩者一旦分岔（app 進沙盒後 home 變成 container home 就會分岔），畫面就會指著一個
	///   根本沒被連過的路徑說「這裡沒有 socket」。路徑事實只留一份。
	public init(endpoint: DaemonEndpoint) {
		let client: NymphClient = .init(socketPath: URL(fileURLWithPath: endpoint.socketPath))
		self.init { request in
			try await client.send(request)
		}
	}

	public func listSessions(includeStopped: Bool) async throws -> ListResult {
		switch try await send(.list(ListParams(all: includeStopped))) {
		case let .list(result):
			return result

		case let .toolError(error):
			throw error

		default:
			throw UnexpectedDaemonResponse()
		}
	}

	public func sessionStatus(id: String) async throws -> StatusResult {
		switch try await send(.status(StatusParams(id: id))) {
		case let .status(result):
			return result

		case let .toolError(error):
			throw error

		default:
			throw UnexpectedDaemonResponse()
		}
	}

	// MARK: Internal

	/// 注入式建構：換掉往返本身，回應分支的判讀（哪個 case 該回、哪個該擲）才測得到——
	/// 加動詞時最容易抄錯的正是這段。
	init(send: @escaping @Sendable (NymphRequest) async throws -> NymphResponse) {
		self.send = send
	}

	// MARK: Private

	private let send: @Sendable (NymphRequest) async throws -> NymphResponse
}
