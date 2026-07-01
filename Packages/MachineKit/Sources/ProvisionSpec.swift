//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一次 provisioning 的輸入規格：要離線建哪個本機帳號、塞哪把 SSH 公鑰、first-boot
/// daemon 的 label。``GuestProvisioner`` 把它翻成一組 ``InjectedFile`` 寫進 guest。
///
/// `password` 只用來算 dslocal 帳號的 SALTED-SHA512-PBKDF2 雜湊——sshd drop-in 是
/// key-only（`PasswordAuthentication no`），密碼不走 SSH，給隨機值只為帳號不留空密碼、
/// 不需回傳呼叫端。
public struct ProvisionSpec: Sendable {

	/// 要離線建立的本機 admin 帳號模型。
	public var user: DslocalUser

	/// 算帳號雜湊用的密碼（建議隨機；key-only SSH 下不作登入用）。
	public var password: String

	/// 寫進 `~/.ssh/authorized_keys` 的 SSH 公鑰（每行一把）。
	public var authorizedKeys: [String]

	/// first-boot LaunchDaemon 的 `Label`（同時決定 plist 檔名）。
	public var firstBootLabel: String

	public init(
		user: DslocalUser,
		password: String,
		authorizedKeys: [String],
		firstBootLabel: String = "me.unpxre.mayfly.firstboot"
	) {
		self.user = user
		self.password = password
		self.authorizedKeys = authorizedKeys
		self.firstBootLabel = firstBootLabel
	}
}
