//
//  NymphKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit
import Testing

// MARK: - NymphProtocolTests

private final class NymphProtocolTests {

	private func roundTrip(_ request: NymphRequest) throws -> NymphRequest {
		try JSONDecoder().decode(NymphRequest.self, from: JSONEncoder().encode(request))
	}

	private func roundTrip(_ response: NymphResponse) throws -> NymphResponse {
		try JSONDecoder().decode(NymphResponse.self, from: JSONEncoder().encode(response))
	}

	/// 每個請求變體 encode → decode 後與原值相等（wire 格式穩定）。
	@Test
	private func `requests round trip`() throws {
		let requests: [NymphRequest] = [
			.spawn(SpawnParams(golden: "base", cpus: 6, memoryGiB: 8, wait: false, readinessTimeoutSeconds: 90)),
			.exec(ExecParams(id: "mfly-1", command: ["ls", "-la"], timeoutSeconds: 30, standardInput: "in", workingDirectory: "/w", environment: ["K": "V"])),
			.ps(PsParams(all: true)),
			.status(StatusParams(id: "mfly-2")),
			.destroy(DestroyParams(id: "mfly-3", force: false)),
		]
		for request in requests {
			#expect(try roundTrip(request) == request)
		}
	}

	/// 每個回應變體 encode → decode 後與原值相等（含 tool-error envelope）。
	@Test
	private func `responses round trip`() throws {
		let summary: SessionSummary = .init(id: "mfly-1", state: .ready, ip: "10.0.0.9", golden: "base", cpus: 4, memoryGiB: 4, uptimeSeconds: 12)
		let responses: [NymphResponse] = [
			.spawn(SpawnResult(id: "mfly-1", state: .booting, ip: nil)),
			.exec(ExecResult(standardOutput: "out\nline", standardError: "err", exit: 3)),
			.ps(PsResult(sessions: [summary])),
			.status(StatusResult(summary: summary, stopReason: "forced")),
			.destroy(DestroyResult(id: "mfly-1")),
			.toolError(ToolError(code: "no_such_id", message: "no such session id: mfly-x")),
		]
		for response in responses {
			#expect(try roundTrip(response) == response)
		}
	}

	/// exec 輸出含換行也安全（JSON 字串轉義 `\n`、payload 保持單行、換行分幀不破）。
	@Test
	private func `exec output with newlines survives round trip`() throws {
		let response: NymphResponse = .exec(ExecResult(standardOutput: "a\nb\nc\n", standardError: "", exit: 0))
		let encoded: Data = try JSONEncoder().encode(response)
		let encodedString: String = String(decoding: encoded, as: UTF8.self)
		#expect(!encodedString.contains("\n"))
		#expect(try roundTrip(response) == response)
	}

	/// NymphError → ToolError 的穩定 code 映射。
	@Test
	private func `tool error codes are stable`() {
		#expect(ToolError(.noSuchID("x")).code == "no_such_id")
		#expect(ToolError(.admissionDenied(limit: 8)).code == "admission_denied")
		#expect(ToolError(.goldenNotFound("g")).code == "golden_not_found")
		#expect(ToolError(.cloneFailed("d")).code == "clone_failed")
		#expect(ToolError(.notReady).code == "not_ready")
		#expect(ToolError(.ipUnavailable).code == "ip_unavailable")
		#expect(ToolError(.transportFailure("d")).code == "transport_failure")
		#expect(ToolError(.execTimedOut).code == "timed_out")
		#expect(ToolError(.notAppleSilicon).code == "not_apple_silicon")
		#expect(ToolError(.internalFailure("d")).code == "internal_error")
	}
}
