//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation
import Testing

private final class SystemProcessLauncherTests {

	/// 兩條串流分開收、結束碼原樣回。
	@Test
	private func `collects both streams and exit code`() async throws {
		let stdout: OutputTailBuffer = .init()
		let stderr: OutputTailBuffer = .init()
		let process: any LaunchedProcess = try SystemProcessRunner().launch(
			executable: "/bin/sh",
			arguments: ["-c", "printf out; printf err >&2; exit 3"],
			standardInput: nil,
			standardOutput: stdout,
			standardError: stderr
		)
		#expect(await process.waitForExit() == 3)
		#expect(stdout.snapshot().text == "out")
		#expect(stderr.snapshot().text == "err")
	}

	/// 行程還在跑時就讀得到已吐出的輸出。
	@Test
	private func `output is visible while running`() async throws {
		let stdout: OutputTailBuffer = .init()
		let process: any LaunchedProcess = try SystemProcessRunner().launch(
			executable: "/bin/sh",
			arguments: ["-c", "printf early; sleep 30"],
			standardInput: nil,
			standardOutput: stdout,
			standardError: .init()
		)
		var seen: Bool = false
		for _ in 0 ..< 100 where !seen {
			seen = stdout.snapshot().text == "early"
			if !seen {
				try await Task.sleep(for: .milliseconds(50))
			}
		}
		#expect(seen)
		process.terminate()
		#expect(await process.waitForExit() == SIGTERM)
	}

	/// stdin 寫入後關閉：`cat` 讀完即結束。
	@Test
	private func `standard input is written then closed`() async throws {
		let stdout: OutputTailBuffer = .init()
		let process: any LaunchedProcess = try SystemProcessRunner().launch(
			executable: "/bin/cat",
			arguments: [],
			standardInput: Data("hello".utf8),
			standardOutput: stdout,
			standardError: .init()
		)
		#expect(await process.waitForExit() == 0)
		#expect(stdout.snapshot().text == "hello")
	}

	/// 執行檔不存在：啟動即擲。
	@Test
	private func `launch throws when executable missing`() {
		#expect(throws: (any Error).self) {
			_ = try SystemProcessRunner().launch(
				executable: "/nonexistent/definitely-not-a-binary",
				arguments: [],
				standardInput: nil,
				standardOutput: .init(),
				standardError: .init()
			)
		}
	}
}
