//
//  mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import NymphKit

/// 背景 exec 三個動詞（`execute --detach`／`exec-output`／`exec-cancel`）共用的判斷：終局怎麼
/// 換成退出碼、輪詢何時停、兩個背景 exec 專屬的錯誤怎麼講給人聽。
///
/// 全是純函式（輪詢的請求出口與等待由呼叫端注入），命令本身只負責把結果寫到 stdout／stderr。
internal enum DetachedExecSupport {

	/// 背景 exec 的終局換成本行程的退出碼與一句說明。
	///
	/// 與 `execute` 同一套慣例：命令自行結束時**結束碼是資料**、原樣當退出碼；沒能跑完
	/// （逾時、SSH 傳輸失敗、被取消）則記一行錯誤、退出碼 1。
	///
	/// - Parameters:
	///   - result: daemon 回的輸出與狀態。
	///   - execID: 背景 exec 的 id（只用在說明句裡）。
	/// - Returns: 還在跑時為 nil；否則為退出碼，以及沒能跑完時要記的錯誤句。
	internal static func termination(
		of result: ExecOutputResult,
		execID: String
	) -> (exit: Int32, error: String?)? {
		switch result.state {
		case .running:
			nil
		case .exited:
			(result.exit ?? 1, result.exit == nil ? "exec \(execID) exited without an exit code" : nil)
		case .timedOut:
			(1, "exec \(execID) timed out and was terminated")
		case .failed:
			(1, "exec \(execID) failed: the SSH transport broke (details on stderr)")
		case .cancelled:
			(1, "exec \(execID) was cancelled")
		}
	}

	/// 截短提醒：哪幾條串流不是全文。
	///
	/// - Parameter result: daemon 回的輸出與狀態。
	/// - Returns: 兩條都是全文時為 nil。
	internal static func truncationNotice(for result: ExecOutputResult) -> String? {
		var streams: [String] = []
		if result.standardOutputTruncated {
			streams.append("stdout")
		}
		if result.standardErrorTruncated {
			streams.append("stderr")
		}
		guard !streams.isEmpty else { return nil }
		return "output is not complete (\(streams.joined(separator: ", ")) shows only the retained tail)"
	}

	/// 背景 exec 專屬的兩個錯誤碼換成講得出下一步的句子；其他錯誤照 daemon 給的訊息。
	///
	/// - Parameter error: daemon 回的工具錯誤。
	/// - Returns: 帶穩定錯誤碼前綴的一行說明。
	internal static func describe(_ error: ToolError) -> String {
		switch error.code {
		case "exec_not_found":
			"[\(error.code)] \(error.message) (it was never started, or its record has been evicted)"
		case "exec_not_running":
			"[\(error.code)] \(error.message) (use exec-output to read its result)"
		default:
			"[\(error.code)] \(error.message)"
		}
	}

	/// 工具錯誤 → 記一行 error（見 ``describe(_:)``）+ `ExitCode(1)`。
	///
	/// - Parameter error: daemon 回的工具錯誤。
	/// - Returns: 給呼叫端擲出的退出碼。
	internal static func fail(_ error: ToolError) -> ExitCode {
		CommandOutput.logger.log(level: .error, "\(describe(error))")
		return ExitCode(1)
	}

	/// 輪詢到背景 exec 結束為止，回結束後的那份輸出。
	///
	/// 跑著時每一輪只問狀態（`tailBytes` 給 0、不搬輸出），看到結束才以呼叫端要的 `tailBytes`
	/// 再取一次——長命令輪詢幾百次也不會每次都把整段輸出傳一遍。
	///
	/// - Parameters:
	///   - execID: 背景 exec 的 id。
	///   - tailBytes: 結束後那一次每條串流取多少 bytes；nil＝全部。
	///   - pause: 兩輪之間的等待。
	///   - send: 送一個請求、收一個回應。
	/// - Returns: 結束後那一次的回應；中途收到非 `execOutput` 的回應（工具錯誤等）原樣回傳。
	internal static func waitUntilEnded(
		execID: String,
		tailBytes: Int?,
		pause: () async throws -> Void,
		send: (NymphRequest) async throws -> NymphResponse
	) async throws -> NymphResponse {
		while true {
			let probe: NymphResponse = try await send(.execOutput(ExecOutputParams(execID: execID, tailBytes: 0)))
			guard case let .execOutput(result) = probe else { return probe }
			guard result.state == .running else { break }
			try await pause()
		}
		return try await send(.execOutput(ExecOutputParams(execID: execID, tailBytes: tailBytes)))
	}
}
