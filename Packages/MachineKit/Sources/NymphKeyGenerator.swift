//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// nymph 身份金鑰的產生器抽象：在 `privateKeyURL` 生成一對金鑰（私鑰寫
/// `privateKeyURL`、公鑰寫同名 + `.pub`）。抽成協定讓 ``NymphHostKey`` 的
/// load-or-generate 邏輯可注入假產生器單測（不必真跑 ssh-keygen）。真實作
/// ``SystemNymphKeyGenerator`` 呼叫系統 `ssh-keygen`。
public protocol NymphKeyGenerator: Sendable {

	/// 在 `privateKeyURL` 生成金鑰對（含 `<path>.pub`），`comment` 寫進公鑰註解。
	/// 父目錄須已存在（由 ``NymphHostKey`` 保證）；``NymphHostKey`` 只在缺鑰時呼叫，
	/// 故毋須處理既存檔覆寫。
	func generate(privateKeyURL: URL, comment: String) async throws
}

/// 呼叫系統 `ssh-keygen` 生成 ed25519 金鑰對的 ``NymphKeyGenerator``。
///
/// `ssh-keygen -t ed25519 -N "" -f <path> -C <comment>`：無 passphrase（daemon 非互動、
/// 私鑰以 state dir 檔案權限保護）、ed25519（短、快、現代預設）。ssh-keygen 自己把
/// 私鑰寫 0600、公鑰寫 `<path>.pub`。透過 ``ProcessRunner`` 執行、非零 exit 轉
/// ``NymphHostKeyError/keygenFailed(status:stderr:)``。
public struct SystemNymphKeyGenerator: NymphKeyGenerator {

	public func generate(privateKeyURL: URL, comment: String) async throws {
		let result: ProcessRunResult = try await runner.run(
			executable: executable,
			arguments: ["-t", "ed25519", "-N", "", "-f", privateKeyURL.path, "-C", comment],
			standardInput: nil,
			timeout: nil
		)
		guard result.exitCode == 0 else {
			throw NymphHostKeyError.keygenFailed(
				status: result.exitCode,
				stderr: String(decoding: result.standardError, as: UTF8.self)
			)
		}
	}

	/// - Parameters:
	///   - runner: 執行 ssh-keygen 的行程執行器，預設 ``SystemProcessRunner``。
	///   - executable: ssh-keygen 路徑，預設 `/usr/bin/ssh-keygen`。
	public init(runner: any ProcessRunner = SystemProcessRunner(), executable: String = "/usr/bin/ssh-keygen") {
		self.runner = runner
		self.executable = executable
	}

	// MARK: Private

	/// 執行 ssh-keygen 的行程執行器。
	private let runner: any ProcessRunner

	/// ssh-keygen 二進位路徑。
	private let executable: String
}
