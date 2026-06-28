//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 離線注入的 first-boot 收尾元件產生器。
///
/// ``SetupAssistantSkip`` 的標記讓 guest 跳過 Setup Assistant、``DslocalUser`` 建好
/// 帳號，但有些事只能在 guest **第一次開機時**於 guest 內完成（開 sshd、清
/// opendirectoryd 快取、回報 readiness）。本型別產生一個一次性的 LaunchDaemon
/// （plist + root script）+ sshd drop-in，離線寫進 bundle，開機跑一次後自我停用。
///
/// 產出純 ``InjectedFile`` 值、不寫任何檔案，內容可純紙上單測；script 的實際行為
/// （kill-loop 是否真壓得住 26 的 Setup Assistant、launchctl 是否在沒 bootstrap 過的
/// image 上把 sshd 拉起來）只能真機驗證。
///
/// **單一來源、需真機 read-back**：注入路徑（`/Library/LaunchDaemons`、
/// `/private/etc/ssh/sshd_config.d`、`/usr/local/libexec`）依 Data 卷 firmlink 慣例
/// 推定；Setup Assistant 的 process label、launchctl service 路徑須對真機核對。
public enum FirstBootDaemon {

	// MARK: Public

	/// first-boot 注入的全部檔案：LaunchDaemon plist、root script、sshd drop-in。
	///
	/// - Parameters:
	///   - user: 已離線建立的本機帳號 shortName，供 opendirectoryd reconcile 重申。
	///   - label: LaunchDaemon 的 `Label`，同時決定 plist 檔名。
	public static func layers(
		forUser user: String,
		label: String = "me.unpxre.mayfly.firstboot"
	) throws -> [InjectedFile] {
		try [
			InjectedFile(
				relativePath: "Library/LaunchDaemons/\(label).plist",
				contents: plist(label: label),
				owner: (0, 0),
				mode: 0o644
			),
			InjectedFile(
				relativePath: scriptRelativePath,
				contents: Data(script(forUser: user, label: label).utf8),
				owner: (0, 0),
				mode: 0o755
			),
			InjectedFile(
				relativePath: "private/etc/ssh/sshd_config.d/01-mayfly.conf",
				contents: Data(sshdDropIn.utf8),
				owner: (0, 0),
				mode: 0o644
			)
		]
	}

	/// 一次性 LaunchDaemon 的 plist：`RunAtLoad=true`、**不設** `KeepAlive`（跑一次、
	/// 不重啟）；`StandardOut/ErrorPath` 導到 log 供 triage。
	public static func plist(label: String) throws -> Data {
		let dictionary: [String: Any] = [
			"Label": label,
			"ProgramArguments": ["/bin/sh", "/\(scriptRelativePath)"],
			"RunAtLoad": true,
			"StandardOutPath": "/var/log/mayfly-firstboot.log",
			"StandardErrorPath": "/var/log/mayfly-firstboot.log"
		]
		return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
	}

	/// root script：跳過 Setup Assistant 的殘留 → 開 sshd → 清 opendirectoryd →
	/// 回報 readiness → 自我停用並刪除。寫成 `#!/bin/sh`。
	///
	/// 設計依據（provisioning 切片對抗驗證）：
	/// - sshd 走 **launchctl service 路徑**（`enable` + `bootstrap`），非
	///   `systemsetup -setremotelogin`（FDA/TCC 閘在呼叫端 process、root 清不掉）。
	/// - `bootstrap` 前先 `bootout` 清殘留 service 紀錄（否則首次常回 IO error 5）。
	/// - kill-loop 視為 mandatory-until-disproven（26 的 Setup Assistant 可能短暫
	///   重生）；process label 待真機核對。
	public static func script(forUser user: String, label: String) -> String {
		"""
		#!/bin/sh
		# Mayfly first-boot provisioning finisher — runs once, then self-disables.
		set -u

		# 1. Suppress any transient Setup Assistant (markers alone may not hold on 26).
		i=0
		while [ "$i" -lt 30 ]; do
			pkill -x "Setup Assistant" 2>/dev/null
			i=$((i + 1))
			sleep 0.5
		done

		# 2. Enable sshd via the launchctl service path (NOT systemsetup).
		#    bootout first to clear any stale record (avoids first-run IO error 5).
		launchctl bootout system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null
		launchctl enable system/com.openssh.sshd 2>/dev/null
		launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null

		# 3. Reconcile the offline-injected dslocal user (opendirectoryd cache).
		dscacheutil -flushcache 2>/dev/null
		killall opendirectoryd 2>/dev/null
		dseditgroup -o edit -a "\(user)" -t user admin 2>/dev/null

		# 4. Report readiness on the serial console (network-independent signal).
		IP=$(ipconfig getifaddr en0 2>/dev/null)
		echo "PROVISIONING_READY user=\(user) ip=${IP:-none}" > /dev/console

		# 5. Self-disable WITHOUT self-bootout: a bootout of our OWN job would SIGTERM
		#    this running script before the cleanup below executes. RunAtLoad +
		#    no-KeepAlive means the job goes inactive on exit 0; the disable override
		#    plus the removed plist stop any future load (each ephemeral clone must
		#    NOT re-run this — otherwise every boot pays the 15s kill-loop again).
		launchctl disable "system/\(label)" 2>/dev/null
		rm -f "/Library/LaunchDaemons/\(label).plist" "/\(scriptRelativePath)"
		exit 0
		"""
	}

	// MARK: Internal

	/// sshd 硬化 drop-in。檔名 `01-`：OpenSSH 的 `Include …/sshd_config.d/*` 走
	/// **字典序 first-match-wins**，`01-` 排在 Apple 預設 `100-macos.conf` 之前而勝出
	/// （`99-` 字典序反而落在 `100-` 之後、會輸——這是 verifier 推翻的常見誤解）。
	/// `KbdInteractiveAuthentication no` 與 `PasswordAuthentication no` 必須並列：缺
	/// 前者時 PAM keyboard-interactive 仍能走密碼登入、`PasswordAuthentication no`
	/// 形同虛設、key-only 政策不生效。
	static let sshdDropIn = """
		PasswordAuthentication no
		KbdInteractiveAuthentication no
		PubkeyAuthentication yes
		PermitRootLogin no
		"""

	// MARK: Private

	/// root script 的注入相對路徑（`/usr/local/libexec` 落在 Data 卷）。
	private static let scriptRelativePath = "usr/local/libexec/mayfly-firstboot.sh"
}
