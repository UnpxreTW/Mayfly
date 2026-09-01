//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 三面向外殼（app / CLI / MCP）共用的 **guest 內命令執行**引擎切片：以 nymph 穩定
/// 身份鑰（``NymphHostKey``）SSH 進 guest 現時 IP、跑命令、回 ``GuestExecResult``。契約
/// 見 #31 決策① / 實作順序①。
///
/// **通道 = SSH（非 console）**：golden provisioning 已把 nymph 公鑰注入 runner 帳號的
/// `authorized_keys`（見 ``MacGuestProvisioner`` / ``ProvisionSpec/authorizedKeys``）、sshd 為
/// key-only（見 ``FirstBootDaemon``）；本型別以對應私鑰連入。**結束碼是資料**——遠端
/// 命令非零退出照常回在 ``GuestExecResult/exitCode``；唯傳輸層失敗（連不上 / 認證被拒 /
/// 逾時 / ssh 起不來）擲 ``MacGuestExecError``。
///
/// 無共享可變狀態（身份 / 使用者 / 執行器皆 `let`）、天然 `Sendable`——daemon 持單一
/// 實例即可對任意 session 併發執行。VM 生命週期不歸這裡（屬 ``MacGuestSession``）；本型別
/// 只做「一次連入、一次執行」。
///
/// **MVP 依賴取捨（待使用者確認）**：現以 Foundation `Process` 呼叫系統 `ssh` /
/// `ssh-keygen`（零新外部依賴）。引入 swift-nio-ssh / Citadel 等原生 SSH 客戶端可換掉
/// 對系統二進位的依賴、細分傳輸錯誤、去掉 255 誤判邊界（見下），屬**新外部依賴、留待
/// 使用者定奪**、不在本切片擅引。
public struct MacGuestExec: Sendable {

	// MARK: Public

	/// - Parameters:
	///   - identity: nymph 穩定身份鑰（提供 `ssh -i` 的私鑰路徑）。
	///   - username: 連入的 guest 帳號，預設 `runner`（golden 注入公鑰的那個帳號）。
	///   - runner: 跑 ssh 的行程執行器，預設 ``SystemProcessRunner``；測試注入假執行器。
	///   - sshExecutable: ssh 二進位路徑，預設 `/usr/bin/ssh`。
	public init(
		identity: NymphHostKey,
		username: String = "runner",
		runner: any ProcessRunner = SystemProcessRunner(),
		sshExecutable: String = "/usr/bin/ssh"
	) {
		self.identity = identity
		self.username = username
		self.runner = runner
		self.sshExecutable = sshExecutable
	}

	/// 以 nymph 私鑰 SSH 進 `ipAddress` 跑 `command`（argv），回 ``GuestExecResult``。
	///
	/// - Parameters:
	///   - command: 遠端命令 argv（非空；ssh 以登入 shell 跑、各片段硬跳脫保 argv 邊界）。
	///   - ipAddress: guest 現時 IP（由呼叫端 / session overload 以 ``MacGuestLease`` 解出）。
	///   - timeout: 整體上限；同時下給 ssh `ConnectTimeout`（連線層）與行程壁鐘（見
	///     ``SystemProcessRunner``）。nil＝不設限。
	///   - standardInput: 餵給遠端命令 stdin 的文字；nil＝無輸入（送 EOF）。
	///   - workingDirectory: 遠端執行前 `cd` 的目錄；nil＝登入預設目錄。
	///   - environment: 遠端命令的額外環境變數（走 `env K=V`、不依賴 sshd `AcceptEnv`）。
	/// - Returns: stdout / stderr / 結束碼（非零是資料、不擲錯）。
	/// - Throws: ``MacGuestExecError/transportFailure(_:)``（ssh 255）/ ``MacGuestExecError/timedOut(_:)``
	///   / ``MacGuestExecError/launchFailed(_:)``。
	public func run(
		_ command: [String],
		onHost ipAddress: String,
		timeout: Duration? = nil,
		standardInput: String? = nil,
		workingDirectory: String? = nil,
		environment: [String: String] = [:]
	) async throws -> GuestExecResult {
		let arguments: [String] = sshArguments(
			ipAddress: ipAddress,
			command: command,
			timeout: timeout,
			workingDirectory: workingDirectory,
			environment: environment
		)
		let outcome: ProcessRunResult
		do {
			outcome = try await runner.run(
				executable: sshExecutable,
				arguments: arguments,
				standardInput: standardInput.map { Data($0.utf8) },
				timeout: timeout
			)
		} catch let error as ProcessRunnerError {
			switch error {
			case let .timedOut(duration):
				throw MacGuestExecError.timedOut(duration)
			}
		} catch {
			throw MacGuestExecError.launchFailed(String(describing: error))
		}
		// ssh 以 255 收斂＝SSH 層錯誤（man ssh：「exits with 255 if an error occurred」）：
		// 連線 / 認證 / 通道失敗。其餘結束碼是遠端命令的真實退出碼（資料）。已知邊界：
		// 真的以 255 退出的遠端命令會被誤判為傳輸失敗——system-ssh MVP 的取捨、原生 SSH
		// 客戶端可去除（見型別註解的依賴取捨）。
		if outcome.exitCode == Self.sshTransportFailureCode {
			throw MacGuestExecError.transportFailure(Self.decodeUTF8(outcome.standardError))
		}
		return GuestExecResult(
			standardOutput: Self.decodeUTF8(outcome.standardOutput),
			standardError: Self.decodeUTF8(outcome.standardError),
			exitCode: outcome.exitCode
		)
	}

	// MARK: Internal

	/// 組 ssh argv：私鑰 + 非互動硬化 + 連線逾時 + `user@ip` + 遠端命令字串。抽 internal
	/// 供單元測試直接驗 argv 構造（不必真跑 ssh）。
	///
	/// **不碰 known_hosts**（`StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`）：
	/// ephemeral guest 每台 host key 不同、TOFU 只會噪音兼卡住；`BatchMode=yes` 杜絕任何
	/// 互動提示（key-only、無 fallback 到密碼）；`LogLevel=ERROR` 壓掉 known-hosts 警告。
	func sshArguments(
		ipAddress: String,
		command: [String],
		timeout: Duration?,
		workingDirectory: String?,
		environment: [String: String]
	) -> [String] {
		var arguments: [String] = [
			"-i", identity.privateKeyURL.path,
			"-o", "BatchMode=yes",
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
			"-o", "LogLevel=ERROR"
		]
		if let timeout {
			arguments += ["-o", "ConnectTimeout=\(max(1, Int(timeout.components.seconds)))"]
		}
		arguments.append("\(username)@\(ipAddress)")
		arguments.append(Self.remoteCommand(
			command: command,
			workingDirectory: workingDirectory,
			environment: environment
		))
		return arguments
	}

	// MARK: Private

	/// ssh 的傳輸層錯誤 sentinel 結束碼（man ssh）。
	private static let sshTransportFailureCode: Int32 = 255

	/// nymph 穩定身份鑰。
	private let identity: NymphHostKey

	/// 連入的 guest 帳號。
	private let username: String

	/// 跑 ssh 的行程執行器。
	private let runner: any ProcessRunner

	/// ssh 二進位路徑。
	private let sshExecutable: String

	/// 把 argv + cwd + env 組成單一遠端 shell 命令字串。ssh 以登入 shell 跑單一字串、
	/// 不保留 argv 邊界——每片段都 POSIX 單引號硬跳脫（含 arg / cwd / env 值），杜絕
	/// 空白 / glob / `$` / `;` 在遠端被 re-split 或展開。env 走 `env K=V …` 前綴（不靠
	/// sshd `AcceptEnv`、預設多半關）、鍵排序求輸出穩定；cwd 走 `cd '<dir>' && `。
	private static func remoteCommand(
		command: [String],
		workingDirectory: String?,
		environment: [String: String]
	) -> String {
		var prefix = ""
		if let workingDirectory {
			prefix += "cd \(shellQuote(workingDirectory)) && "
		}
		if !environment.isEmpty {
			let assignments: String = environment
				.sorted { $0.key < $1.key }
				.map { "\($0.key)=\(shellQuote($0.value))" }
				.joined(separator: " ")
			prefix += "env \(assignments) "
		}
		return prefix + command.map(shellQuote).joined(separator: " ")
	}

	/// POSIX sh 單引號硬跳脫：整段包單引號、內部單引號替換成 `'\''`（收單引號 → 字面
	/// 單引號 → 再開單引號）。空字串回 `''`。
	private static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// UTF-8 解碼（無法解的 byte 走替代字元、不失長度）。
	private static func decodeUTF8(_ data: Data) -> String {
		String(decoding: data, as: UTF8.self)
	}
}

#if arch(arm64)

// MacGuestSession 觸碰 VZ（arm64 限定）——session overload 整段 arch gate，核心 ip-based
// run 不受影響（純 Foundation、可跨 arch 建 / 測）。
public extension MacGuestExec {

	/// 以 `session` 現時 IP 執行 `command`。語意同 ``run(_:onHost:timeout:standardInput:workingDirectory:environment:)``、
	/// 只是 IP 由 session 解出：狀態非 ready → ``MacGuestExecError/notReady``；解不到 IP →
	/// ``MacGuestExecError/ipUnavailable``。
	func run(
		_ command: [String],
		on session: MacGuestSession,
		timeout: Duration? = nil,
		standardInput: String? = nil,
		workingDirectory: String? = nil,
		environment: [String: String] = [:]
	) async throws -> GuestExecResult {
		let ipAddress: String = try await resolveIP(of: session)
		return try await run(
			command,
			onHost: ipAddress,
			timeout: timeout,
			standardInput: standardInput,
			workingDirectory: workingDirectory,
			environment: environment
		)
	}

	/// 解 session 的目標 IP：狀態非 ready → notReady；ready 則先以 ``MacGuestLease/currentIP(macAddress:leasesFile:)``
	/// 現查（長駐 daemon 下比開機當下的 readiness IP 更即時）、退回 readiness 解出的 IP；
	/// 兩者皆無 → ipUnavailable。
	private func resolveIP(of session: MacGuestSession) async throws -> String {
		guard case let .ready(readinessIP) = await session.state else {
			throw MacGuestExecError.notReady
		}
		if let live = liveIP(of: session) {
			return live
		}
		if let readinessIP {
			return readinessIP
		}
		throw MacGuestExecError.ipUnavailable
	}

	/// 從 session 的 bundle metadata 取 MAC、以 ``MacGuestLease`` 現查 host lease。讀不到
	/// metadata / lease 無此 MAC → nil（交由 ``resolveIP(of:)`` fallback）。
	private func liveIP(of session: MacGuestSession) -> String? {
		let metadataURL: URL = MacGuestBundleLayout.metadata(in: session.bundle.bundle)
		guard
			let data = try? Data(contentsOf: metadataURL),
			let metadata = try? JSONDecoder().decode(BundleMetadata.self, from: data)
		else {
			return nil
		}
		return MacGuestLease.currentIP(macAddress: metadata.macAddress)
	}
}

#endif
