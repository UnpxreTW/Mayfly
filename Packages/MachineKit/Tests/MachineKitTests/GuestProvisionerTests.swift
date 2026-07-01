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

private func sampleSpec(keys: [String] = ["ssh-ed25519 AAAAExample account@host"]) -> ProvisionSpec {
	ProvisionSpec(
		user: DslocalUser(shortName: "runner", uid: 501, realName: "Mayfly Runner"),
		password: "correct horse battery staple",
		authorizedKeys: keys,
		firstBootLabel: "test.firstboot"
	)
}

private func provisionAttachPlist() throws -> Data {
	try PropertyListSerialization.data(
		fromPropertyList: ["system-entities": [
			["dev-entry": "/dev/disk8", "content-hint": "GUID_partition_scheme"],
			["dev-entry": "/dev/disk8s2"]
		]],
		format: .xml,
		options: 0
	)
}

/// disk8 上有 System+Data 主 container → Data 卷 disk11s5（與 mounter 測共用形狀）。
private func provisionApfsPlist() throws -> Data {
	let container: [String: Any] = [
		"PhysicalStores": [["DeviceIdentifier": "disk8s2"]],
		"Volumes": [
			["DeviceIdentifier": "disk11s1", "Roles": ["System"]],
			["DeviceIdentifier": "disk11s5", "Roles": ["Data"]]
		]
	]
	return try PropertyListSerialization.data(fromPropertyList: ["Containers": [container]], format: .xml, options: 0)
}

private func makeBundleWithDiskImage() throws -> URL {
	let bundle = FileManager.default.temporaryDirectory.appending(path: "gp-\(UUID().uuidString).bundle")
	try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
	try Data().write(to: GuestBundleLayout.diskImage(in: bundle))
	return bundle
}

// MARK: - GuestProvisionerTests

private final class GuestProvisionerTests {

	/// payload 串出 12 檔：dslocal 使用者紀錄 + Setup Assistant 跳過（7）+ first-boot（3）+ authorized_keys。
	@Test
	private func `payload assembles all injected files`() throws {
		let files = try GuestProvisioner.payload(spec: sampleSpec())
		#expect(files.count == 12)
	}

	/// dslocal 使用者紀錄落正確路徑、root:wheel 0600。
	@Test
	private func `payload writes dslocal user record`() throws {
		let files = try GuestProvisioner.payload(spec: sampleSpec())
		let record = try #require(files.first {
			$0.relativePath == "private/var/db/dslocal/nodes/Default/users/runner.plist"
		})
		#expect(record.owner.uid == 0)
		#expect(record.owner.gid == 0)
		#expect(record.mode == 0o600)
	}

	/// authorized_keys 落帳號自有 .ssh、owner=帳號、0600、內容為公鑰逐行。
	@Test
	private func `payload writes authorized keys owned by account`() throws {
		let files = try GuestProvisioner.payload(spec: sampleSpec(keys: ["key-one", "key-two"]))
		let keys = try #require(files.first { $0.relativePath == "Users/runner/.ssh/authorized_keys" })
		#expect(keys.owner.uid == 501)
		#expect(keys.owner.gid == 20)
		#expect(keys.mode == 0o600)
		let text = try #require(String(bytes: keys.contents, encoding: .utf8))
		#expect(text == "key-one\nkey-two\n")
	}

	/// first-boot daemon 的 plist 檔名帶 spec 的 label（label threading）。
	@Test
	private func `payload threads first boot label`() throws {
		let files = try GuestProvisioner.payload(spec: sampleSpec())
		#expect(files.contains { $0.relativePath == "Library/LaunchDaemons/test.firstboot.plist" })
	}

	/// Setup Assistant 跳過標記在 payload 內（.AppleSetupDone）。
	@Test
	private func `payload includes setup assistant skip`() throws {
		let files = try GuestProvisioner.payload(spec: sampleSpec())
		#expect(files.contains { $0.relativePath == "private/var/db/.AppleSetupDone" })
	}

	/// 掛載回報 locked → provision 轉 requiresRecoveryFallback，且收尾有 detach。
	@Test
	private func `provision routes locked mount to recovery fallback`() async throws {
		let bundle = try makeBundleWithDiskImage()
		defer { try? FileManager.default.removeItem(at: bundle) }
		let attachPlist = try provisionAttachPlist()
		let apfsPlist = try provisionApfsPlist()
		let fake = FakeCommandRunner { executable, arguments in
			if arguments.first == "attach" {
				return .success(attachPlist)
			}
			if arguments.first == "apfs" {
				return .success(apfsPlist)
			}
			if arguments.first == "mount" {
				return .failure(GuestVolumeMounterError.commandFailed(
					executable: executable,
					status: 66,
					stderr: "Volume on disk11s5 is locked"
				))
			}
			return .success(Data())
		}
		let provisioner: GuestProvisioner = .init(runner: fake)
		do {
			_ = try await provisioner.provision(bundle: bundle, spec: sampleSpec())
			Issue.record("預期擲 requiresRecoveryFallback")
		} catch GuestProvisionerError.requiresRecoveryFallback {
			// 預期路徑
		} catch {
			Issue.record("預期 .requiresRecoveryFallback、得 \(error)")
		}
		#expect(fake.calls.contains { $0.arguments == ["detach", "/dev/disk8"] })
	}

	/// 非 locked 的中途失敗 → 原錯原樣上拋（不誤轉 requiresRecoveryFallback）、且收尾有 detach。
	/// 釘住 generic catch arm 的合約：detach-on-failure + 原錯穿透，防兩個 catch arm 被互調。
	@Test
	private func `provision detaches and rethrows non-locked failure`() async throws {
		let bundle = try makeBundleWithDiskImage()
		defer { try? FileManager.default.removeItem(at: bundle) }
		let attachPlist = try provisionAttachPlist()
		let apfsPlist = try provisionApfsPlist()
		let fake = FakeCommandRunner { executable, arguments in
			if arguments.first == "attach" {
				return .success(attachPlist)
			}
			if arguments.first == "apfs" {
				return .success(apfsPlist)
			}
			if arguments.first == "mount" {
				return .failure(GuestVolumeMounterError.commandFailed(
					executable: executable,
					status: 1,
					stderr: "could not mount disk11s5: Input/output error"
				))
			}
			return .success(Data())
		}
		let provisioner: GuestProvisioner = .init(runner: fake)
		do {
			_ = try await provisioner.provision(bundle: bundle, spec: sampleSpec())
			Issue.record("預期擲原始 commandFailed")
		} catch GuestProvisionerError.requiresRecoveryFallback {
			Issue.record("非 locked 失敗不應被轉成 requiresRecoveryFallback")
		} catch GuestVolumeMounterError.commandFailed {
			// 預期：原始錯誤原樣上拋
		}
		#expect(fake.calls.contains { $0.arguments == ["detach", "/dev/disk8"] })
	}
}
