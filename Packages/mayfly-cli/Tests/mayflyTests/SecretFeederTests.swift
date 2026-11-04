//
//  mayflyTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import mayfly
import Foundation
import Testing

// MARK: - SecretFeederTests

private final class SecretFeederTests {

	/// 命令讀到的是「密碼一行、接著輸入結束」：第一行等於值、再讀就是 EOF。
	@Test
	private func `command reads exactly one line then end of input`() async throws {
		let script: String = #"IFS= read -r line || exit 2; [ "$line" = "fake-secret" ] || exit 3; "#
			+ #"IFS= read -r more && exit 4; [ -z "$more" ] || exit 5; exit 0"#
		let status: Int32 = try await SecretFeeder.run(["/bin/sh", "-c", script], secret: Data("fake-secret".utf8))
		#expect(status == 0)
	}

	/// 命令的結束碼原樣回。
	@Test
	private func `exit status passes through`() async throws {
		let status: Int32 = try await SecretFeeder.run(["/bin/sh", "-c", "exit 7"], secret: Data("fake-secret".utf8))
		#expect(status == 7)
	}

	/// 命令不讀 stdin 就結束、寫入撞上已關的 pipe：本行程不被 SIGPIPE 殺掉，照樣回命令的結束碼。
	/// 值放大到超過 pipe 緩衝，寫入一定會在命令結束後才寫到斷點。
	@Test
	private func `early exit does not raise sigpipe`() async throws {
		let large: Data = .init(repeating: 0x66, count: 1 << 20)
		let status: Int32 = try await SecretFeeder.run(["/bin/sh", "-c", "exec 0<&-; exit 7"], secret: large)
		#expect(status == 7)
	}

	/// 被訊號終止：128 加訊號編號。
	@Test
	private func `signal termination maps to 128 plus signal`() async throws {
		let status: Int32 = try await SecretFeeder.run(["/bin/sh", "-c", "kill -TERM $$"], secret: Data("fake-secret".utf8))
		#expect(status == 128 + SIGTERM)
	}

	/// 命令經 `PATH` 找得到；找不到時 `env` 以 127 結束。
	@Test
	private func `missing command reports 127`() async throws {
		let status: Int32 = try await SecretFeeder.run(["mayfly-definitely-not-a-command"], secret: Data("fake-secret".utf8))
		#expect(status == 127)
	}
}
