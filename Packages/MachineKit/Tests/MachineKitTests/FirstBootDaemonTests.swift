//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import MachineKit

final class FirstBootDaemonTests {

	/// 三個注入檔（plist / script / sshd drop-in）、owner 皆 root:wheel、mode 正確。
	@Test func layersAreThreeFilesWithCorrectOwnerMode() throws {
		let layers = try FirstBootDaemon.layers(forUser: "runner")
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
	@Test func plistRunAtLoadAndNoKeepAlive() throws {
		let dictionary = try decodePlist(FirstBootDaemon.plist(label: "test.label"))
		#expect(dictionary["RunAtLoad"] as? Bool == true)
		#expect(dictionary["KeepAlive"] == nil)
		#expect(dictionary["Label"] as? String == "test.label")
		#expect((dictionary["ProgramArguments"] as? [String])?.first == "/bin/sh")
	}

	/// sshd 走 launchctl service 路徑、絕不用 systemsetup。
	@Test func scriptUsesLaunchctlNotSystemsetup() {
		let script = FirstBootDaemon.script(forUser: "runner", label: "test.label")
		#expect(script.contains("launchctl enable system/com.openssh.sshd"))
		#expect(script.contains("launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"))
		#expect(!script.contains("systemsetup"))
	}

	/// bootstrap 前先 bootout 清殘留（避免首次 IO error 5）。
	@Test func scriptBootoutPrecedesBootstrap() throws {
		let script = FirstBootDaemon.script(forUser: "runner", label: "test.label")
		let bootout = try #require(script.range(of: "launchctl bootout system /System/Library/LaunchDaemons/ssh.plist"))
		let bootstrap = try #require(script.range(of: "launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"))
		#expect(bootout.lowerBound < bootstrap.lowerBound)
	}

	/// script 含 kill-loop / readiness marker / opendirectoryd reconcile / 自我刪除。
	@Test func scriptHasKillLoopReconcileReadinessSelfDisable() {
		let script = FirstBootDaemon.script(forUser: "runner", label: "test.label")
		#expect(script.contains("pkill -x \"Setup Assistant\""))
		#expect(script.contains("dscacheutil -flushcache"))
		#expect(script.contains("killall opendirectoryd"))
		#expect(script.contains("dseditgroup -o edit -a \"runner\""))
		#expect(script.contains("PROVISIONING_READY"))
		#expect(script.contains("rm -f"))
	}

	/// sshd drop-in 政策：關密碼、開金鑰、禁 root 登入。
	@Test func sshdDropInPolicy() {
		#expect(FirstBootDaemon.sshdDropIn.contains("PasswordAuthentication no"))
		#expect(FirstBootDaemon.sshdDropIn.contains("PubkeyAuthentication yes"))
		#expect(FirstBootDaemon.sshdDropIn.contains("PermitRootLogin no"))
	}

	/// drop-in 檔名 01- 字典序排在 Apple 預設 100-macos.conf 之前（first-match 勝出）。
	@Test func confFilenameSortsBeforeAppleDefault() throws {
		let layers = try FirstBootDaemon.layers(forUser: "runner")
		let conf = try #require(layers.first { $0.relativePath.hasSuffix("01-mayfly.conf") })
		let filename = try #require(conf.relativePath.split(separator: "/").last.map(String.init))
		#expect(filename < "100-macos.conf")
	}
}
