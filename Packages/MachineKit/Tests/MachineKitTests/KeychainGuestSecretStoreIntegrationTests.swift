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

// MARK: - KeychainGuestSecretStoreIntegrationTests

/// 對真的 `security` 跑一輪：暫存 keychain 檔、測完即刪，不碰使用者的 keychain。
///
/// 假執行器只證明送出去的指令長什麼樣子；`security -i` 收不收那一行、讀回來是什麼形狀，
/// 要真的跑一次才知道。
private final class KeychainGuestSecretStoreIntegrationTests {

	/// 存、讀、覆寫、刪、刪後讀與再刪都照預期。
	@Test
	private func `round trip against a scratch keychain`() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appending(component: "mayfly-secret-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let keychain: String = directory.appending(component: "scratch.keychain-db").path
		let runner: SystemProcessRunner = .init()
		let created: ProcessRunResult = try await runner.run(
			executable: "/usr/bin/security",
			arguments: ["create-keychain", "-p", "fake-keychain-password", keychain],
			standardInput: nil,
			timeout: .seconds(30)
		)
		try #require(created.exitCode == 0)
		defer {
			// 從搜尋清單拿掉並刪檔；失敗只留下暫存目錄裡的檔，不影響結果。
			let process: Process = .init()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
			process.arguments = ["delete-keychain", keychain]
			try? process.run()
			process.waitUntilExit()
			try? FileManager.default.removeItem(at: directory)
		}

		let store: KeychainGuestSecretStore = .init(keychain: keychain)
		try await store.setSecret(Data("fake-secret \"q\" \\".utf8), for: "golden-test")
		#expect(try await store.secret(for: "golden-test") == Data("fake-secret \"q\" \\".utf8))
		try await store.setSecret(Data("假的-fake-2".utf8), for: "golden-test")
		#expect(try await store.secret(for: "golden-test") == Data("假的-fake-2".utf8))
		try await store.removeSecret(for: "golden-test")
		await #expect(throws: GuestSecretStoreError.notFound(alias: "golden-test")) {
			try await store.secret(for: "golden-test")
		}
		await #expect(throws: GuestSecretStoreError.notFound(alias: "golden-test")) {
			try await store.removeSecret(for: "golden-test")
		}
		let missing: String = directory.appending(component: "missing.keychain-db").path
		await #expect(throws: GuestSecretStoreError.keychainNotFound(path: missing)) {
			try await KeychainGuestSecretStore(keychain: missing).setSecret(Data("fake-secret".utf8), for: "golden-test")
		}
	}
}
