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

/// 一律以固定結束碼與輸出回應的假執行器。
private func respondingRunner(exit: Int32 = 0, stdout: String = "", stderr: String = "") -> FakeProcessRunner {
	FakeProcessRunner { _, _, _ in
		.success(ProcessRunResult(standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8), exitCode: exit))
	}
}

/// 位元組 → 十六進位文字（測試自己算一份，不借受測型別的實作）。
private func hexText(_ text: String) -> String {
	Data(text.utf8).map { String(format: "%02x", $0) }.joined()
}

// MARK: - KeychainGuestSecretStoreTests

private final class KeychainGuestSecretStoreTests {

	/// 寫入：整行指令走 `security -i` 的 stdin，argv 只有 `-i`；值以十六進位文字存、再以 `-X` 的十六進位交出。
	@Test
	private func `set sends the command over stdin only`() async throws {
		let runner: FakeProcessRunner = respondingRunner()
		let store: KeychainGuestSecretStore = .init(runner: runner)
		try await store.setSecret(Data("fake-secret".utf8), for: "golden-xcode")
		let call: FakeProcessRunner.Call = try #require(runner.calls.first)
		#expect(runner.calls.count == 1)
		#expect(call.executable == "/usr/bin/security")
		#expect(call.arguments == ["-i"])
		let payload: String = hexText(hexText("fake-secret"))
		let expected: String = "add-generic-password -U -a golden-xcode -s \"Mayfly guest admin password\" "
			+ "-l \"Mayfly guest admin password\" -X \(payload)\n"
		#expect(call.standardInput == Data(expected.utf8))
		#expect(!call.arguments.joined(separator: " ").contains("fake-secret"))
	}

	/// 指定 keychain：寫入那行以雙引號收路徑，讀取與刪除接在 argv 最後。
	@Test
	private func `explicit keychain is appended`() async throws {
		let keychain: String = "/tmp/fake dir/mayfly.keychain-db"
		let runner: FakeProcessRunner = respondingRunner(stdout: hexText("fake-secret") + "\n")
		let store: KeychainGuestSecretStore = .init(keychain: keychain, runner: runner, fileExists: { _ in true })
		try await store.setSecret(Data("fake-secret".utf8), for: "a")
		_ = try await store.secret(for: "a")
		try await store.removeSecret(for: "a")
		let calls: [FakeProcessRunner.Call] = runner.calls
		let service: String = KeychainGuestSecretStore.service
		let line: String = try String(decoding: #require(calls.first?.standardInput), as: UTF8.self)
		#expect(line.hasSuffix(" \"\(keychain)\"\n"))
		#expect(calls[1].arguments == ["find-generic-password", "-a", "a", "-s", service, "-w", keychain])
		#expect(calls[2].arguments == ["delete-generic-password", "-a", "a", "-s", service, keychain])
	}

	/// 讀取：stdout 的十六進位文字解回原值（含非 ASCII），結尾換行不算進去。
	@Test
	private func `get decodes the stored hex`() async throws {
		let store: KeychainGuestSecretStore = .init(runner: respondingRunner(stdout: hexText("假的-fake") + "\n"))
		#expect(try await store.secret(for: "golden-xcode") == Data("假的-fake".utf8))
	}

	/// 項目內容不是十六進位（別處手動建的同名項目）→ 不當成密碼交出去。
	@Test(arguments: ["fake-secret\n", "abc\n", "zz\n", "\n"])
	private func `foreign item content is rejected`(stdout: String) async {
		let store: KeychainGuestSecretStore = .init(runner: respondingRunner(stdout: stdout))
		await #expect(throws: GuestSecretStoreError.malformedItem(alias: "a")) {
			try await store.secret(for: "a")
		}
	}

	/// 結束碼映射：44＝找不到、152＝鎖著或拒絕授權、其餘照碼回報。
	@Test(arguments: [
		(Int32(44), GuestSecretStoreError.notFound(alias: "a")),
		(152, .keychainUnavailable("denied")),
		(36, .keychainUnavailable("denied")),
		(1, .commandFailed(status: 1, message: "denied"))
	])
	private func `exit status mapping`(status: Int32, expected: GuestSecretStoreError) async {
		let store: KeychainGuestSecretStore = .init(runner: respondingRunner(exit: status, stderr: "denied\n"))
		await #expect(throws: expected) {
			try await store.secret(for: "a")
		}
		await #expect(throws: expected) {
			try await store.removeSecret(for: "a")
		}
	}

	/// 寫入失敗時，錯誤訊息裡出現的值（兩種編碼）一律遮掉。
	@Test
	private func `set failure message never carries the value`() async {
		let inner: String = hexText("fake-secret")
		let outer: String = hexText(inner)
		let store: KeychainGuestSecretStore = .init(runner: respondingRunner(exit: 2, stderr: "bad \(outer) / \(inner)"))
		await #expect(throws: GuestSecretStoreError.commandFailed(status: 2, message: "bad <redacted> / <redacted>")) {
			try await store.setSecret(Data("fake-secret".utf8), for: "a")
		}
	}

	/// 逾時映成 ``GuestSecretStoreError/timedOut(_:)``，其他執行期錯誤映成起不來。
	@Test
	private func `runner errors are mapped`() async {
		let timingOut: FakeProcessRunner = .init { _, _, _ in .failure(ProcessRunnerError.timedOut(.seconds(30))) }
		await #expect(throws: GuestSecretStoreError.timedOut(.seconds(30))) {
			try await KeychainGuestSecretStore(runner: timingOut).secret(for: "a")
		}
		let failing: FakeProcessRunner = .init { _, _, _ in .failure(CocoaError(.fileNoSuchFile)) }
		await #expect(throws: GuestSecretStoreError.self) {
			try await KeychainGuestSecretStore(runner: failing).secret(for: "a")
		}
	}

	/// 指定的 keychain 檔不存在：三種操作都擋在呼叫 `security` 之前（`security` 寫入時會改寫進 default keychain）。
	@Test
	private func `missing keychain file never reaches security`() async {
		let runner: FakeProcessRunner = respondingRunner()
		let keychain: String = "/tmp/fake-missing.keychain-db"
		let store: KeychainGuestSecretStore = .init(keychain: keychain, runner: runner, fileExists: { _ in false })
		let expected: GuestSecretStoreError = .keychainNotFound(path: keychain)
		await #expect(throws: expected) {
			try await store.setSecret(Data("fake-secret".utf8), for: "a")
		}
		await #expect(throws: expected) {
			try await store.secret(for: "a")
		}
		await #expect(throws: expected) {
			try await store.removeSecret(for: "a")
		}
		#expect(runner.calls.isEmpty)
	}

	/// 別名、值、keychain 路徑任一不合規：擋在呼叫 `security` 之前。
	@Test
	private func `invalid input never reaches security`() async {
		let runner: FakeProcessRunner = respondingRunner()
		let store: KeychainGuestSecretStore = .init(runner: runner)
		await #expect(throws: GuestSecretStoreError.invalidAlias("bad alias")) {
			try await store.setSecret(Data("fake-secret".utf8), for: "bad alias")
		}
		await #expect(throws: GuestSecretStoreError.invalidAlias("-a")) {
			try await store.secret(for: "-a")
		}
		await #expect(throws: GuestSecretStoreError.invalidSecret(.containsLineBreak)) {
			try await store.setSecret(Data("fake\nsecret".utf8), for: "a")
		}
		await #expect(throws: GuestSecretStoreError.invalidSecret(.empty)) {
			try await store.setSecret(Data(), for: "a")
		}
		let quoted: KeychainGuestSecretStore = .init(keychain: "/tmp/a\"b", runner: runner)
		await #expect(throws: GuestSecretStoreError.invalidKeychainPath("/tmp/a\"b")) {
			try await quoted.setSecret(Data("fake-secret".utf8), for: "a")
		}
		let relativePath: String = "fake.keychain-db"
		let relative: KeychainGuestSecretStore = .init(keychain: relativePath, runner: runner, fileExists: { _ in true })
		await #expect(throws: GuestSecretStoreError.invalidKeychainPath(relativePath)) {
			try await relative.secret(for: "a")
		}
		#expect(runner.calls.isEmpty)
	}
}
