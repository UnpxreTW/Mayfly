//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import NymphKit

/// daemon-client 動詞（spawn / exec / list / status / destroy&lt;id&gt;）的共用執行——連 nymph
/// socket、送請求、把傳輸失敗與非預期回應收斂成一致的 stderr + 非零退出。薄殼紀律：真正的
/// 編排在 daemon 的 `SessionStore`、CLI 只做 argv ↔ socket ↔ stdout 轉接。
enum NymphClientSupport {

	/// 送請求；連不上 daemon → stderr + `ExitCode(1)`。工具錯誤（toolError）由呼叫端各自
	/// 以 ``fail(_:)`` 收斂（不同動詞的成功分支不同、無法在此統一 switch）。
	static func send(_ request: NymphRequest) async throws -> NymphResponse {
		do {
			return try await NymphClient().send(request)
		} catch let error as NymphTransportError {
			FileHandle.standardError.write(Data("nymph: \(describe(error))\n".utf8))
			throw ExitCode(1)
		}
	}

	/// 工具錯誤 → stderr（帶穩定 code）+ `ExitCode(1)`。
	static func fail(_ error: ToolError) -> ExitCode {
		FileHandle.standardError.write(Data("error [\(error.code)]: \(error.message)\n".utf8))
		return ExitCode(1)
	}

	/// 非預期回應型別（協議錯配）→ stderr + `ExitCode(1)`。
	static func unexpectedResponse() -> ExitCode {
		FileHandle.standardError.write(Data("nymph: unexpected response for request\n".utf8))
		return ExitCode(1)
	}

	/// `KEY=VALUE` 清單 → 字典（首個 `=` 切；缺 `=` 擲 usage error）。
	static func parseEnvironment(_ pairs: [String]) throws -> [String: String] {
		var environment: [String: String] = [:]
		for pair in pairs {
			guard let separator = pair.firstIndex(of: "=") else {
				throw ValidationError("--env must be KEY=VALUE: \(pair)")
			}
			environment[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
		}
		return environment
	}

	/// 傳輸錯誤的人讀訊息。
	private static func describe(_ error: NymphTransportError) -> String {
		switch error {
		case .connectFailed:
			return "cannot reach the nymph daemon (is `mayfly nymph` running?)"

		case .connectionClosed:
			return "connection closed before a response arrived"

		case let .pathTooLong(path):
			return "socket path too long: \(path)"

		case let .bindFailed(path, detail):
			return "bind failed at \(path): \(detail)"

		case let .socketCreationFailed(detail):
			return "socket() failed: \(detail)"

		case let .listenFailed(detail):
			return "listen() failed: \(detail)"
		}
	}
}
