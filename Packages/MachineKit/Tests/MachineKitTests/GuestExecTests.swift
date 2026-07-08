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

private func sampleIdentity() -> NymphHostKey {
	NymphHostKey(
		privateKeyURL: URL(fileURLWithPath: "/tmp/nymph_ed25519"),
		publicKeyLine: "ssh-ed25519 AAAANYMPH mayfly-nymph"
	)
}

private func okRunner(
	exit: Int32 = 0,
	stdout: String = "",
	stderr: String = ""
) -> FakeProcessRunner {
	FakeProcessRunner { _, _, _ in
		.success(ProcessRunResult(
			standardOutput: Data(stdout.utf8),
			standardError: Data(stderr.utf8),
			exitCode: exit
		))
	}
}

// MARK: - GuestExecTests

private final class GuestExecTests {

	/// argv 帶私鑰 + 非互動硬化 + `user@ip` + 遠端命令字串（POSIX 硬跳脫保 argv 邊界）。
	@Test
	private func `ssh arguments carry identity hardening and command`() {
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: okRunner())
		let arguments = exec.sshArguments(
			ipAddress: "192.168.64.5",
			command: ["echo", "hi"],
			timeout: nil,
			workingDirectory: nil,
			environment: [:]
		)
		#expect(arguments.contains("-i"))
		#expect(arguments.contains("/tmp/nymph_ed25519"))
		#expect(arguments.contains("BatchMode=yes"))
		#expect(arguments.contains("StrictHostKeyChecking=no"))
		#expect(arguments.contains("UserKnownHostsFile=/dev/null"))
		#expect(arguments[arguments.count - 2] == "runner@192.168.64.5")
		#expect(arguments.last == "'echo' 'hi'")
	}

	/// timeout 非 nil → 下 ssh `ConnectTimeout`（秒、至少 1）。
	@Test
	private func `timeout adds connect timeout option`() {
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: okRunner())
		let arguments = exec.sshArguments(
			ipAddress: "10.0.0.1",
			command: ["true"],
			timeout: .seconds(5),
			workingDirectory: nil,
			environment: [:]
		)
		#expect(arguments.contains("ConnectTimeout=5"))
	}

	/// cwd + env 串進遠端命令字串：`cd '<dir>' && env K=V … <cmd>`、env 鍵排序穩定。
	@Test
	private func `working directory and environment thread into remote command`() {
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: okRunner())
		let arguments = exec.sshArguments(
			ipAddress: "10.0.0.1",
			command: ["ls"],
			timeout: nil,
			workingDirectory: "/tmp/w",
			environment: ["A": "1", "B": "x y"]
		)
		#expect(arguments.last == "cd '/tmp/w' && env A='1' B='x y' 'ls'")
	}

	/// 遠端命令非零退出＝資料：exit 42 原樣回傳、不擲錯；stdout / stderr 解碼帶回。
	@Test
	private func `nonzero exit is data not error`() async throws {
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: okRunner(exit: 42, stdout: "out", stderr: "err"))
		let result = try await exec.run(["false"], onHost: "10.0.0.1")
		#expect(result.exitCode == 42)
		#expect(result.standardOutput == "out")
		#expect(result.standardError == "err")
	}

	/// exit 0 → stdout 解碼回傳、exitCode 0。
	@Test
	private func `zero exit returns decoded output`() async throws {
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: okRunner(exit: 0, stdout: "hello\n"))
		let result = try await exec.run(["echo", "hello"], onHost: "10.0.0.1")
		#expect(result.exitCode == 0)
		#expect(result.standardOutput == "hello\n")
	}

	/// ssh 以 255 收斂＝SSH 傳輸失敗 → 擲 transportFailure、帶 ssh stderr。
	@Test
	private func `ssh 255 maps to transport failure`() async throws {
		let exec: GuestExec = .init(
			identity: sampleIdentity(),
			runner: okRunner(exit: 255, stderr: "Permission denied (publickey).")
		)
		do {
			_ = try await exec.run(["true"], onHost: "10.0.0.1")
			Issue.record("預期擲 transportFailure")
		} catch let GuestExecError.transportFailure(stderr) {
			#expect(stderr.contains("Permission denied"))
		} catch {
			Issue.record("預期 transportFailure、得 \(error)")
		}
	}

	/// 執行器擲 timedOut → 映成 ``GuestExecError/timedOut(_:)``（帶原逾時長度）。
	@Test
	private func `timeout error maps to timed out`() async throws {
		let runner: FakeProcessRunner = .init { _, _, _ in .failure(ProcessRunnerError.timedOut(.seconds(3))) }
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: runner)
		await #expect(throws: GuestExecError.timedOut(.seconds(3))) {
			try await exec.run(["sleep", "10"], onHost: "10.0.0.1", timeout: .seconds(3))
		}
	}

	/// ssh 起不來（spawn 失敗）→ 映成 launchFailed（非傳輸失敗、非逾時）。
	@Test
	private func `launch failure maps to launch failed`() async throws {
		struct Boom: Error {}
		let runner: FakeProcessRunner = .init { _, _, _ in .failure(Boom()) }
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: runner)
		do {
			_ = try await exec.run(["true"], onHost: "10.0.0.1")
			Issue.record("預期擲 launchFailed")
		} catch GuestExecError.launchFailed {
			// 預期路徑
		} catch {
			Issue.record("預期 launchFailed、得 \(error)")
		}
	}

	/// stdin 文字轉 bytes 餵進行程 stdin（ssh 轉發到遠端命令）；executable 走 ssh 路徑。
	@Test
	private func `standard input and executable pass through`() async throws {
		let runner: FakeProcessRunner = .init { _, _, stdin in
			.success(ProcessRunResult(standardOutput: stdin ?? Data(), standardError: Data(), exitCode: 0))
		}
		let exec: GuestExec = .init(identity: sampleIdentity(), runner: runner, sshExecutable: "/usr/bin/ssh")
		let result = try await exec.run(["cat"], onHost: "10.0.0.1", standardInput: "hello")
		#expect(result.standardOutput == "hello")
		#expect(runner.calls.first?.standardInput == Data("hello".utf8))
		#expect(runner.calls.first?.executable == "/usr/bin/ssh")
	}
}
