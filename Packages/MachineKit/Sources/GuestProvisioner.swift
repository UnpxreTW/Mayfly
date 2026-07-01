//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// provisioning 的**第三軸 orchestrator**：把離線 builder（``DslocalUser`` /
/// ``SetupAssistantSkip`` / ``FirstBootDaemon``）的 payload + authorized_keys 串成一組
/// ``InjectedFile``，經 ``GuestVolumeMounter`` 的 `attach → locate → mount →
/// enableOwnership → write → detach` 寫進剛裝好的 guest bundle，回傳 ``GoldenBundle``。
///
/// **需 root**（`enableOwnership` / `write` 的 numeric chown 要 root；呼叫端負責 `sudo`
/// 或 CI 本就 root）。任何步驟失敗都會先 `detach` 再上拋，不留掛載中的 image。掛載回報
/// `.encryptedLocked` → 轉 ``GuestProvisionerError/requiresRecoveryFallback``（P6 Recovery
/// fallback 的 seam、本型別不自解鎖）。
///
/// **範圍（v1）**：只做離線注入 + GoldenBundle marker。設計的 "seal-boot"（開機跑
/// first-boot daemon、偵測 readiness 後關機封存）依賴尚未建的 ReadinessGate（P5），
/// 另拆後續切片。
public struct GuestProvisioner: Sendable {

	/// 對剛裝好（未 provisioned）的 guest bundle 離線注入帳號 / 跳過 Setup Assistant /
	/// first-boot daemon / authorized_keys，回傳 ``GoldenBundle``。需 root。
	public func provision(bundle: URL, spec: ProvisionSpec) async throws -> GoldenBundle {
		let diskImage: URL = GuestBundleLayout.diskImage(in: bundle)
		let mounter: GuestVolumeMounter = .init(diskImage: diskImage, runner: runner)
		do {
			try await mounter.attach()
			try await mounter.locateDataVolume()
			try await mounter.mount()
			try await mounter.enableOwnership()
			try await mounter.write(Self.payload(spec: spec))
		} catch GuestVolumeMounterError.encryptedLocked {
			try? await mounter.detach()
			throw GuestProvisionerError.requiresRecoveryFallback
		} catch {
			try? await mounter.detach()
			throw error
		}
		try await mounter.detach()
		return GoldenBundle(bundle: bundle)
	}

	public init(runner: any CommandRunner = SystemCommandRunner()) {
		self.runner = runner
	}

	/// 把 spec 翻成離線注入的全部 ``InjectedFile``：dslocal 使用者紀錄（root:wheel 0600）
	/// + Setup Assistant 跳過標記（7）+ first-boot daemon（3）+ authorized_keys
	/// （帳號自有、0600）。純函式、可純紙上單測。
	static func payload(spec: ProvisionSpec) throws -> [InjectedFile] {
		let user = spec.user
		let shadowHashData = try DslocalUser.makeShadowHashData(password: spec.password)
		let userRecord = try user.userPlist(shadowHashData: shadowHashData)
		var files: [InjectedFile] = [
			InjectedFile(
				relativePath: "private/var/db/dslocal/nodes/Default/users/\(user.shortName).plist",
				contents: userRecord,
				owner: (0, 0),
				mode: 0o600
			)
		]
		files += try SetupAssistantSkip.layers(forUser: user.shortName, uid: user.uid)
		files += try FirstBootDaemon.layers(
			forUser: user.shortName,
			uid: user.uid,
			gid: user.primaryGID,
			label: spec.firstBootLabel
		)
		let authorizedKeys: Data = .init((spec.authorizedKeys.joined(separator: "\n") + "\n").utf8)
		files.append(
			InjectedFile(
				relativePath: "Users/\(user.shortName)/.ssh/authorized_keys",
				contents: authorizedKeys,
				owner: (user.uid, user.primaryGID),
				mode: 0o600
			)
		)
		return files
	}

	/// 命令執行器（傳給內部 ``GuestVolumeMounter``；預設真 Process、測試注入假）。
	private let runner: any CommandRunner
}
