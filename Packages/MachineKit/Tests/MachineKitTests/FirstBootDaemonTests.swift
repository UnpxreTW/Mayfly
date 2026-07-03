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

private final class FirstBootDaemonTests {

	/// 三個注入檔（plist / script / sshd drop-in）、owner 皆 root:wheel、mode 正確。
	@Test
	private func `layers are three files with correct owner mode`() throws {
		let layers = try FirstBootDaemon.layers(forUser: "runner", uid: 501, gid: 20)
		#expect(layers.count == 3)

		let plist = try #require(layers.first { $0.relativePath.hasSuffix(".plist") })
		#expect(plist.owner.uid == 0)
		#expect(plist.owner.gid == 0)
		#expect(plist.mode == 0o644)

		let script = try #require(layers.first { $0.relativePath.hasSuffix(".sh") })
		#expect(script.owner.uid == 0)
		#expect(script.mode == 0o755)

		let conf = try #require(layers.first { $0.relativePath.hasSuffix("01-mayfly.conf") })
		#expect(conf.mode == 0o644)
	}

	/// LaunchDaemon plist：RunAtLoad=true、不設 KeepAlive（跑一次不重啟）、Label / args 正確。
	@Test
	private func `plist run at load and no keep alive`() throws {
		let dictionary = try decodePlist(FirstBootDaemon.plist(label: "test.label"))
		#expect(dictionary["RunAtLoad"] as? Bool == true)
		#expect(dictionary["KeepAlive"] == nil)
		#expect(dictionary["Label"] as? String == "test.label")
		#expect((dictionary["ProgramArguments"] as? [String])?.first == "/bin/sh")
	}

	/// sshd 走 launchctl service 路徑、絕不用 systemsetup。
	@Test
	private func `script uses launchctl not systemsetup`() {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		#expect(script.contains("launchctl enable system/com.openssh.sshd"))
		#expect(script.contains("launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"))
		// systemsetup 可出現在說明註解、絕不可被當指令呼叫——濾掉註解行後只驗指令面。
		let executable = script
			.split(separator: "\n")
			.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
			.joined(separator: "\n")
		#expect(!executable.contains("systemsetup"))
	}

	/// bootstrap 前先 bootout 清殘留（避免首次 IO error 5）。
	@Test
	private func `script bootout precedes bootstrap`() throws {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		let bootout = try #require(script.range(of: "launchctl bootout system /System/Library/LaunchDaemons/ssh.plist"))
		let bootstrap = try #require(script.range(of: "launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"))
		#expect(bootout.lowerBound < bootstrap.lowerBound)
	}

	/// script 含 kill-loop / readiness marker / opendirectoryd reconcile / 自我刪除。
	@Test
	private func `script has kill loop reconcile readiness self disable`() {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		#expect(script.contains("pkill -x \"Setup Assistant\""))
		#expect(script.contains("dscacheutil -flushcache"))
		#expect(script.contains("killall opendirectoryd"))
		#expect(script.contains("dseditgroup -o edit -a \"runner\""))
		#expect(script.contains("PROVISIONING_READY"))
		#expect(script.contains("rm -f"))
	}

	/// readiness marker 寫 guest 的 virtio serial 裝置 /dev/cu.virtio（host 收得到、真機驗過）；
	/// /dev/console 不路由到 VZ serial port、只留作次要 echo。兩者皆容錯（無 serial 的開機組態）。
	@Test
	private func `readiness marker targets virtio serial device`() {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		#expect(script.contains("> /dev/cu.virtio 2>/dev/null"))
		let markerLines = script.split(separator: "\n").filter { $0.contains("PROVISIONING_READY") && $0.contains("echo") }
		#expect(markerLines.allSatisfy { $0.contains("2>/dev/null") })
	}

	/// 開機以 numeric chown -R 修正離線注入 home 子樹的屬主、並把 .ssh 收緊 0700。
	@Test
	private func `script chowns injected home subtree`() {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		#expect(script.contains("chown -R 501:20 \"$HOME_DIR\""))
		#expect(script.contains("chmod 700 \"$HOME_DIR/.ssh\""))
	}

	/// 自我停用：移除 payload，但絕不 bootout 自己的 daemon——self-bootout 會 SIGTERM
	/// 正在跑的本 script、cleanup 跑不到，golden image 封進去後每個 clone 都重跑。
	@Test
	private func `self disable removes payload without self bootout`() {
		let script: String = FirstBootDaemon.script(forUser: "runner", uid: 501, gid: 20, label: "test.label")
		#expect(!script.contains("launchctl bootout system \"/Library/LaunchDaemons"))
		#expect(script.contains("launchctl disable \"system/test.label\""))
		#expect(script.contains("rm -f \"/Library/LaunchDaemons/test.label.plist\""))
	}

	/// sshd drop-in 政策：關密碼、開金鑰、禁 root 登入。
	@Test
	private func `sshd drop in policy`() {
		#expect(FirstBootDaemon.sshdDropIn.contains("PasswordAuthentication no"))
		#expect(FirstBootDaemon.sshdDropIn.contains("KbdInteractiveAuthentication no"))
		#expect(FirstBootDaemon.sshdDropIn.contains("PubkeyAuthentication yes"))
		#expect(FirstBootDaemon.sshdDropIn.contains("PermitRootLogin no"))
	}

	/// drop-in 檔名 01- 字典序排在 Apple 預設 100-macos.conf 之前（first-match 勝出）。
	@Test
	private func `conf filename sorts before apple default`() throws {
		let layers = try FirstBootDaemon.layers(forUser: "runner", uid: 501, gid: 20)
		let conf = try #require(layers.first { $0.relativePath.hasSuffix("01-mayfly.conf") })
		let filename = try #require(conf.relativePath.split(separator: "/").last.map(String.init))
		#expect(filename < "100-macos.conf")
	}
}
