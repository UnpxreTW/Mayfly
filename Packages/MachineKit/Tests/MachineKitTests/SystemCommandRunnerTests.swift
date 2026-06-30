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

private final class SystemCommandRunnerTests {

	/// spawn 失敗（執行檔不存在）即擲、**不卡死**——驗 `run()` 排在 drain dispatch 之前，
	/// 失敗路徑不留卡死的 drain thread / 不洩漏 fd。
	@Test
	private func `run throws promptly when executable missing`() async {
		let runner: SystemCommandRunner = .init()
		await #expect(throws: (any Error).self) {
			_ = try await runner.run(executable: "/nonexistent/definitely-not-a-binary", arguments: [])
		}
	}

	/// 成功跑、回 stdout。
	@Test
	private func `run returns stdout on success`() async throws {
		let runner: SystemCommandRunner = .init()
		let output = try await runner.run(executable: "/bin/echo", arguments: ["mayfly-ok"])
		#expect(String(bytes: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "mayfly-ok")
	}

	/// 非零 exit 擲 ``GuestVolumeMounterError/commandFailed(executable:status:stderr:)``（帶 status）。
	@Test
	private func `run throws command failed on nonzero exit`() async {
		let runner: SystemCommandRunner = .init()
		do {
			_ = try await runner.run(executable: "/bin/sh", arguments: ["-c", "exit 3"])
			Issue.record("預期擲 commandFailed")
		} catch let error as GuestVolumeMounterError {
			guard case let .commandFailed(_, status, _) = error else {
				Issue.record("預期 .commandFailed、得 \(error)")
				return
			}
			#expect(status == 3)
		} catch {
			Issue.record("預期 GuestVolumeMounterError、得 \(error)")
		}
	}
}
