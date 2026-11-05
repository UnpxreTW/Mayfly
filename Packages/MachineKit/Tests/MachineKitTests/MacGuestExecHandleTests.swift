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

// MARK: - MacGuestExecHandleTests

private final class MacGuestExecHandleTests {

	/// 遠端命令先記行程群組、再跑跳脫過的 argv；終止腳本對同一個群組檔下手。
	@Test
	private func `remote script records group before command`() throws {
		let launcher: FakeLauncher = .init()
		let exec: MacGuestExec = makeExec(launcher: launcher, runner: quietRunner())
		_ = try exec.start(["echo", "hi"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		let script: String = try #require(launcher.lastArguments.last)
		#expect(script.hasPrefix("{ echo $$ > '/tmp/mayfly-exec-"))
		#expect(script.contains(".pgid'; } 2>/dev/null; [ -e '/tmp/mayfly-exec-"))
		#expect(script.hasSuffix(".pgid.cancel' ] && exit 143; 'echo' 'hi'"))
		#expect(launcher.lastArguments[launcher.lastArguments.count - 2] == "runner@10.0.0.1")
	}

	/// 啟動的那一趟帶連線上限與對端存活探測：沒有整體上限的命令，連不上或中途失聯時都不會無限期掛著。
	@Test
	private func `start bounds connect and detects a lost guest`() throws {
		let launcher: FakeLauncher = .init()
		_ = try makeExec(launcher: launcher, runner: quietRunner())
			.start(["true"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		#expect(launcher.lastArguments.contains("ConnectTimeout=15"))
		#expect(launcher.lastArguments.contains("ServerAliveInterval=15"))
		#expect(launcher.lastArguments.contains("ServerAliveCountMax=4"))
	}

	/// 自行結束：結束碼原樣回、不走終止流程。
	@Test
	private func `natural exit returns exit code`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["true"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		launcher.process.finish(7)
		#expect(await handle.wait() == .exited(7))
		#expect(runner.calls.isEmpty)
		#expect(launcher.process.terminateCount == 0)
	}

	/// ssh 255＝傳輸失敗、帶 stderr。
	@Test
	private func `exit 255 maps to transport failure`() async throws {
		let launcher: FakeLauncher = .init()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: quietRunner())
			.start(["true"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		launcher.process.finish(255)
		#expect(await handle.wait() == .transportFailure("ssh: connect to host failed"))
	}

	/// 逾時：先對 guest 內群組送訊號、再收本機 ssh，終局標逾時。
	@Test
	private func `timeout runs termination and reports timed out`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["sleep", "100"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		#expect(await handle.wait(timeout: .milliseconds(50)) == .timedOut)
		#expect(runner.calls.count == 1)
		let script: String = try #require(runner.calls.first?.arguments.last)
		#expect(script.contains("kill -TERM -- \"-$pg\""))
		#expect(script.contains("kill -KILL -- \"-$pg\""))
		#expect(launcher.process.terminateCount == 1)
	}

	/// 取消與逾時同一條終止流程，終局標取消；重複取消不再跑第二趟。
	@Test
	private func `cancel runs termination once and reports cancelled`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["sleep", "100"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		await handle.cancel()
		await handle.cancel()
		#expect(await handle.wait() == .cancelled)
		#expect(runner.calls.count == 1)
		#expect(launcher.process.terminateCount == 1)
	}

	/// 已結束的命令取消不做事、終局維持原結束碼。
	@Test
	private func `cancel after exit is a no-op`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["true"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		launcher.process.finish(0)
		#expect(await handle.wait() == .exited(0))
		await handle.cancel()
		#expect(await handle.wait() == .exited(0))
		#expect(runner.calls.isEmpty)
	}

	/// 命令結束後、沒有任何人在等的情況下取消：不做事、結束碼不被蓋掉。
	@Test
	private func `cancel after exit without waiter is a no-op`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["true"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		launcher.process.finish(0)
		try await Task.sleep(for: .milliseconds(100))
		await handle.cancel()
		#expect(await handle.wait() == .exited(0))
		#expect(runner.calls.isEmpty)
		#expect(launcher.process.terminateCount == 0)
	}

	/// 計時器只起一次：先帶的上限生效，之後較短的上限不理。
	@Test
	private func `only the first timeout arms the timer`() async throws {
		let launcher: FakeLauncher = .init()
		let runner: FakeProcessRunner = quietRunner()
		let handle: MacGuestExecHandle = try makeExec(launcher: launcher, runner: runner)
			.start(["sleep", "100"], onHost: "10.0.0.1", standardOutput: .init(), standardError: .init())
		let first: Task<MacGuestExecOutcome, Never> = Task { await handle.wait(timeout: .seconds(30)) }
		try await Task.sleep(for: .milliseconds(50))
		let second: Task<MacGuestExecOutcome, Never> = Task { await handle.wait(timeout: .milliseconds(10)) }
		try await Task.sleep(for: .milliseconds(200))
		#expect(runner.calls.isEmpty)
		launcher.process.finish(0)
		#expect(await first.value == .exited(0))
		#expect(await second.value == .exited(0))
	}

	/// 終止腳本：先立取消標記；群組檔讀不到就不送訊號（命令還沒開始跑）；送完刪群組檔。
	@Test
	private func `kill script guards missing group file`() {
		let script: String = MacGuestExec.killGroupScript(groupFile: "/tmp/mayfly-exec-x.pgid")
		#expect(script.hasPrefix("touch '/tmp/mayfly-exec-x.pgid.cancel' 2>/dev/null; "))
		#expect(script.contains("pg=$(cat '/tmp/mayfly-exec-x.pgid' 2>/dev/null) || exit 0; "))
		#expect(script.contains(#"[ -n "$pg" ] || exit 0; "#))
		#expect(script.contains("rm -f '/tmp/mayfly-exec-x.pgid'"))
	}
}

// MARK: - FakeLaunchedProcess

/// 由測試決定何時結束的假行程：``finish(_:)`` 給結束碼；``terminate()`` 以 SIGTERM 的碼結束。
private final class FakeLaunchedProcess: LaunchedProcess, @unchecked Sendable {

	var terminateCount: Int {
		lock.withLock { terminates }
	}

	func finish(_ code: Int32) {
		let waiting: [CheckedContinuation<Int32, Never>] = lock.withLock {
			guard exitCode == nil else { return [] }
			exitCode = code
			defer { waiters = [] }
			return waiters
		}
		for waiter in waiting {
			waiter.resume(returning: code)
		}
	}

	func waitForExit() async -> Int32 {
		await withCheckedContinuation { continuation in
			let code: Int32? = lock.withLock {
				if let exitCode { return exitCode }
				waiters.append(continuation)
				return nil
			}
			if let code {
				continuation.resume(returning: code)
			}
		}
	}

	func terminate() {
		lock.withLock { terminates += 1 }
		finish(SIGTERM)
	}

	private let lock: NSLock = .init()

	private var exitCode: Int32?

	private var waiters: [CheckedContinuation<Int32, Never>] = []

	private var terminates: Int = 0
}

// MARK: - FakeLauncher

/// 記下啟動參數、回同一個 ``FakeLaunchedProcess`` 的假啟動器。
private final class FakeLauncher: ProcessLauncher, @unchecked Sendable {

	var lastArguments: [String] {
		lock.withLock { arguments }
	}

	let process: FakeLaunchedProcess = .init()

	func launch(
		executable: String,
		arguments: [String],
		standardInput: Data?,
		standardOutput: OutputTailBuffer,
		standardError: OutputTailBuffer
	) throws -> any LaunchedProcess {
		lock.withLock { self.arguments = arguments }
		standardError.append(Data("ssh: connect to host failed".utf8))
		return process
	}

	private let lock: NSLock = .init()

	private var arguments: [String] = []
}

/// 以假啟動器與假執行器組一個 ``MacGuestExec``。
private func makeExec(launcher: FakeLauncher, runner: FakeProcessRunner) -> MacGuestExec {
	MacGuestExec(
		identity: NymphHostKey(
			privateKeyURL: URL(fileURLWithPath: "/tmp/nymph_ed25519"),
			publicKeyLine: "ssh-ed25519 AAAANYMPH mayfly-nymph"
		),
		runner: runner,
		launcher: launcher
	)
}

/// 一律回成功、無輸出的假執行器（終止那一趟用）。
private func quietRunner() -> FakeProcessRunner {
	FakeProcessRunner { _, _, _ in .success(ProcessRunResult(standardOutput: Data(), standardError: Data(), exitCode: 0)) }
}
