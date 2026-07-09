//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// daemon-client 端的 socket 客戶端——CLI 的 spawn/exec/ps/status/destroy 動詞（現在）與
/// stdio shim（步③）皆經此連 nymph socket、送一個 ``NymphRequest``、收一個 ``NymphResponse``。
/// 一次請求一條連線（連 → 寫一行 → 讀一行 → 關），簡單且與 server 的逐行協議對稱。
public struct NymphClient: Sendable {

	// MARK: Public

	/// nymph socket 路徑。
	public let socketPath: URL

	/// - Parameter socketPath: 目標 socket；預設 ``NymphPaths/socketURL(environment:)``。
	public init(socketPath: URL = NymphPaths.socketURL()) {
		self.socketPath = socketPath
	}

	/// daemon 是否在跑——嘗試連 socket、連得上即視為在（連完即關）。**NY-2** 的 destroy
	/// path/id 消歧就靠這個判斷（socket 在 → id 語義、不在 → path 語義）。
	public static func isDaemonPresent(socketPath: URL = NymphPaths.socketURL()) -> Bool {
		guard let fd = try? UnixSocket.connect(path: socketPath.path) else {
			return false
		}
		close(fd)
		return true
	}

	/// 送一個請求、收一個回應。連不上 daemon 擲 ``NymphTransportError/connectFailed(_:_:)``；
	/// 回應在讀到完整一行前斷線擲 ``NymphTransportError/connectionClosed``。
	public func send(_ request: NymphRequest) async throws -> NymphResponse {
		let fd: Int32 = try UnixSocket.connect(path: socketPath.path)
		defer { close(fd) }
		let encoded: Data = try JSONEncoder().encode(request)
		var payload: Data = encoded
		payload.append(0x0A)
		guard await UnixSocket.write(payload, to: fd) else {
			throw NymphTransportError.connectionClosed
		}
		let reader: SocketLineReader = .init(fd: fd)
		guard let lineData = await UnixSocket.readLine(from: reader), !lineData.isEmpty else {
			throw NymphTransportError.connectionClosed
		}
		return try JSONDecoder().decode(NymphResponse.self, from: lineData)
	}
}
