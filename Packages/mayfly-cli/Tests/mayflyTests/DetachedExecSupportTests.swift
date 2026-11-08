//
//  mayflyTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import mayfly
import ArgumentParser
import Foundation
import NymphKit
import Testing

// MARK: - DetachedExecSupportTests

private final class DetachedExecSupportTests {

	/// 做一份背景 exec 輸出；沒給的欄位取「全文、無輸出」。
	private static func result(
		state: ExecState,
		exit: Int32? = nil,
		standardOutput: String = "",
		standardOutputTruncated: Bool = false,
		standardErrorTruncated: Bool = false
	) -> ExecOutputResult {
		.init(
			state: state,
			standardOutput: standardOutput,
			standardError: "",
			standardOutputTruncated: standardOutputTruncated,
			standardErrorTruncated: standardErrorTruncated,
			lastOutputAt: nil,
			exit: exit,
			endedAt: nil
		)
	}

	/// 還在跑：沒有終局。
	@Test
	private func `running has no termination`() {
		#expect(DetachedExecSupport.termination(of: Self.result(state: .running), execID: "exec-1") == nil)
	}

	/// 自行結束：結束碼原樣當退出碼、不記錯誤——非零也一樣。
	@Test
	private func `exited passes the exit code through`() throws {
		let zero: (exit: Int32, error: String?) = try #require(
			DetachedExecSupport.termination(of: Self.result(state: .exited, exit: 0), execID: "exec-1")
		)
		#expect(zero.exit == 0)
		#expect(zero.error == nil)
		let failing: (exit: Int32, error: String?) = try #require(
			DetachedExecSupport.termination(of: Self.result(state: .exited, exit: 42), execID: "exec-1")
		)
		#expect(failing.exit == 42)
		#expect(failing.error == nil)
	}

	/// 沒能跑完的三種終局：退出碼 1，並各有一句帶 id 的錯誤。
	@Test
	private func `unfinished endings exit with one and explain`() throws {
		for state in [ExecState.timedOut, .failed, .cancelled] {
			let ending: (exit: Int32, error: String?) = try #require(
				DetachedExecSupport.termination(of: Self.result(state: state), execID: "exec-9")
			)
			#expect(ending.exit == 1)
			let message: String = try #require(ending.error)
			#expect(message.contains("exec-9"))
		}
	}

	/// 只有截短的那幾條串流被點名；都是全文時不提醒。
	@Test
	private func `truncation notice names only truncated streams`() throws {
		#expect(DetachedExecSupport.truncationNotice(for: Self.result(state: .running)) == nil)
		let bothResult: ExecOutputResult = Self.result(
			state: .running,
			standardOutputTruncated: true,
			standardErrorTruncated: true
		)
		let both: String = try #require(DetachedExecSupport.truncationNotice(for: bothResult))
		#expect(both.contains("stdout, stderr"))
		let errorOnlyResult: ExecOutputResult = Self.result(state: .running, standardErrorTruncated: true)
		let errorOnly: String = try #require(DetachedExecSupport.truncationNotice(for: errorOnlyResult))
		#expect(errorOnly.contains("(stderr "))
		#expect(!errorOnly.contains("stdout"))
	}

	/// 背景 exec 專屬的兩個錯誤碼補上下一步；錯誤碼前綴照留。其他錯誤原樣。
	@Test
	private func `exec specific errors get a next step`() {
		let notFound: String = DetachedExecSupport.describe(ToolError(code: "exec_not_found", message: "no such exec id: x"))
		#expect(notFound.hasPrefix("[exec_not_found] no such exec id: x ("))
		#expect(notFound.contains("evicted"))
		let notRunning: String = DetachedExecSupport.describe(
			ToolError(code: "exec_not_running", message: "exec has already ended: x")
		)
		#expect(notRunning.hasPrefix("[exec_not_running] exec has already ended: x ("))
		#expect(notRunning.contains("exec-output"))
		let other: String = DetachedExecSupport.describe(ToolError(code: "no_such_id", message: "no such id: y"))
		#expect(other == "[no_such_id] no such id: y")
	}

	/// 輪詢：跑著時只問狀態（tailBytes 0）、每輪之間等一次；看到結束後以呼叫端的 tailBytes 再取一次。
	@Test
	private func `wait polls until the exec ends`() async throws {
		let recorder: Recorder = .init(replies: [
			.execOutput(Self.result(state: .running)),
			.execOutput(Self.result(state: .running)),
			.execOutput(Self.result(state: .exited, exit: 3)),
			.execOutput(Self.result(state: .exited, exit: 3, standardOutput: "done"))
		])
		let final: NymphResponse = try await DetachedExecSupport.waitUntilEnded(
			execID: "exec-1",
			tailBytes: 128,
			pause: { recorder.pauses += 1 },
			send: { recorder.send($0) }
		)
		#expect(final == .execOutput(Self.result(state: .exited, exit: 3, standardOutput: "done")))
		#expect(recorder.pauses == 2)
		#expect(recorder.requests == [
			.execOutput(ExecOutputParams(execID: "exec-1", tailBytes: 0)),
			.execOutput(ExecOutputParams(execID: "exec-1", tailBytes: 0)),
			.execOutput(ExecOutputParams(execID: "exec-1", tailBytes: 0)),
			.execOutput(ExecOutputParams(execID: "exec-1", tailBytes: 128))
		])
	}

	/// 輪詢中途收到工具錯誤：原樣回傳、不再多送一次。
	@Test
	private func `wait returns a tool error as is`() async throws {
		let error: ToolError = .init(code: "exec_not_found", message: "no such exec id: exec-1")
		let recorder: Recorder = .init(replies: [.toolError(error)])
		let final: NymphResponse = try await DetachedExecSupport.waitUntilEnded(
			execID: "exec-1",
			tailBytes: nil,
			pause: { recorder.pauses += 1 },
			send: { recorder.send($0) }
		)
		#expect(final == .toolError(error))
		#expect(recorder.requests.count == 1)
		#expect(recorder.pauses == 0)
	}

	/// `--detach` 是選項，要放在 id 之前；放在命令後面就屬於遠端命令。
	@Test
	private func `detach flag parses before the id only`() throws {
		let detached: ExecuteCommand = try ExecuteCommand.parse(["--detach", "mfly-1", "sleep", "5"])
		#expect(detached.detach)
		#expect(detached.command == ["sleep", "5"])
		let passthrough: ExecuteCommand = try ExecuteCommand.parse(["mfly-1", "echo", "--detach"])
		#expect(!passthrough.detach)
		#expect(passthrough.command == ["echo", "--detach"])
	}

	/// `exec-output` 拒收負的 `--tail-bytes` 與小於 1 秒的輪詢間隔。
	@Test
	private func `exec output rejects bad numbers`() {
		#expect(throws: (any Error).self) {
			try ExecOutputCommand.parse(["exec-1", "--tail-bytes", "-1"])
		}
		#expect(throws: (any Error).self) {
			try ExecOutputCommand.parse(["exec-1", "--wait", "--poll-interval", "0"])
		}
		#expect(throws: Never.self) {
			try ExecOutputCommand.parse(["exec-1", "--tail-bytes", "0", "--wait", "--poll-interval", "2"])
		}
	}
}

// MARK: - Recorder

/// 測試輔助：依序回預先排好的回應，並記下收到的請求與等待次數。
private final class Recorder {

	/// - Parameter replies: 依序要回的回應。
	fileprivate init(replies: [NymphResponse]) {
		self.replies = replies
	}

	/// 收到的請求，依先後。
	fileprivate var requests: [NymphRequest] = []

	/// `pause` 被呼叫的次數。
	fileprivate var pauses: Int = 0

	/// 尚未送出的回應。
	fileprivate var replies: [NymphResponse]

	/// 記下請求、回下一個排好的回應；排完了就回一個工具錯誤，讓多送的那一次在斷言裡看得出來。
	fileprivate func send(_ request: NymphRequest) -> NymphResponse {
		requests.append(request)
		guard !replies.isEmpty else { return .toolError(ToolError(code: "test_exhausted", message: "no more replies")) }
		return replies.removeFirst()
	}
}
