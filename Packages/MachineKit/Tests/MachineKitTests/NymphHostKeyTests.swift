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

/// 依設定寫檔 / 擲錯的假 ``NymphKeyGenerator``：驗 load-or-generate 邏輯、不跑真
/// ssh-keygen。`failure` 非 nil 則擲；否則把 `publicKeyContents` 寫成 `.pub`、私鑰寫
/// 佔位 bytes。`callCount` 供 idempotent 驗證（第二次應載入、不重生）。
private final class FakeNymphKeyGenerator: NymphKeyGenerator, @unchecked Sendable {

	init(publicKeyContents: String = "ssh-ed25519 AAAAFAKE mayfly-nymph", failure: (any Error)? = nil) {
		self.publicKeyContents = publicKeyContents
		self.failure = failure
	}

	var callCount: Int {
		lock.withLock { count }
	}

	func generate(privateKeyURL: URL, comment: String) async throws {
		lock.withLock { count += 1 }
		if let failure {
			throw failure
		}
		try Data("PRIVATE-KEY-PLACEHOLDER".utf8).write(to: privateKeyURL)
		try Data((publicKeyContents + "\n").utf8).write(to: privateKeyURL.appendingPathExtension("pub"))
	}

	private let publicKeyContents: String

	private let failure: (any Error)?

	private let lock: NSLock = .init()

	private var count = 0
}

private func makeStateDirectory() -> URL {
	FileManager.default.temporaryDirectory.appending(component: "nymph-\(UUID().uuidString)")
}

// MARK: - NymphHostKeyTests

private final class NymphHostKeyTests {

	/// 首啟生成、爾後載入同一把（idempotent）：第二次不重呼 generator、公鑰不變。
	@Test
	private func `load or generate creates then reloads same key`() async throws {
		let directory = makeStateDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let generator: FakeNymphKeyGenerator = .init(publicKeyContents: "ssh-ed25519 AAAAFAKE mayfly-nymph")
		let key = try await NymphHostKey.loadOrGenerate(in: directory, generator: generator)
		#expect(key.publicKeyLine == "ssh-ed25519 AAAAFAKE mayfly-nymph")
		#expect(FileManager.default.fileExists(atPath: key.privateKeyURL.path))
		#expect(generator.callCount == 1)
		let again = try await NymphHostKey.loadOrGenerate(in: directory, generator: generator)
		#expect(again.publicKeyLine == key.publicKeyLine)
		#expect(again.privateKeyURL == key.privateKeyURL)
		#expect(generator.callCount == 1)
	}

	/// generator 擲錯 → loadOrGenerate 上拋（不吞、不留半成品身份）。
	@Test
	private func `generation failure surfaces`() async throws {
		let directory = makeStateDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let generator: FakeNymphKeyGenerator = .init(failure: NymphHostKeyError.keygenFailed(status: 1, stderr: "boom"))
		await #expect(throws: NymphHostKeyError.keygenFailed(status: 1, stderr: "boom")) {
			try await NymphHostKey.loadOrGenerate(in: directory, generator: generator)
		}
	}

	/// 公鑰檔可讀但為空 → publicKeyEmpty（不成一條 authorized_keys 條目）。
	@Test
	private func `empty public key throws`() async throws {
		let directory = makeStateDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let generator: FakeNymphKeyGenerator = .init(publicKeyContents: "")
		do {
			_ = try await NymphHostKey.loadOrGenerate(in: directory, generator: generator)
			Issue.record("預期擲 publicKeyEmpty")
		} catch NymphHostKeyError.publicKeyEmpty {
			// 預期路徑
		} catch {
			Issue.record("預期 publicKeyEmpty、得 \(error)")
		}
	}

	/// 真 ssh-keygen round-trip：生成得合法 ed25519 公鑰、reload 得同一把（穩定身份）。
	@Test
	private func `real ssh keygen round trip`() async throws {
		let directory = makeStateDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = try await NymphHostKey.loadOrGenerate(in: directory)
		#expect(key.publicKeyLine.hasPrefix("ssh-ed25519 "))
		let reloaded = try await NymphHostKey.loadOrGenerate(in: directory)
		#expect(reloaded.publicKeyLine == key.publicKeyLine)
		#expect(reloaded.privateKeyURL == key.privateKeyURL)
	}

	/// 注入 round-trip：nymph 公鑰併進 ``ProvisionSpec/authorizedKeys`` → ``MacGuestProvisioner``
	/// 的 authorized_keys 檔逐行含之（沿用現行 provisioning 管線、無需改引擎）。
	@Test
	private func `nymph public key injects into provisioning authorized keys`() throws {
		let key: NymphHostKey = .init(
			privateKeyURL: URL(fileURLWithPath: "/state/nymph_ed25519"),
			publicKeyLine: "ssh-ed25519 AAAANYMPH mayfly-nymph"
		)
		let spec: ProvisionSpec = .init(
			user: DslocalUser(shortName: "runner", uid: 501, realName: "Mayfly Runner"),
			password: "correct horse battery staple",
			authorizedKeys: ["ssh-ed25519 AAAAEXISTING ci@host", key.publicKeyLine],
			firstBootLabel: "test.firstboot"
		)
		let files = try MacGuestProvisioner.payload(spec: spec)
		let authorized = try #require(files.first { $0.relativePath == "Users/runner/.ssh/authorized_keys" })
		let text = try #require(String(bytes: authorized.contents, encoding: .utf8))
		#expect(text.contains(key.publicKeyLine))
		#expect(text == "ssh-ed25519 AAAAEXISTING ci@host\nssh-ed25519 AAAANYMPH mayfly-nymph\n")
	}
}
