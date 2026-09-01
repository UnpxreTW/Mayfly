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

private func hdiutilAttachPlist(wholeDisk: String, slices: [String]) throws -> Data {
	var entities: [[String: Any]] = [["dev-entry": "/dev/\(wholeDisk)", "content-hint": "GUID_partition_scheme"]]
	entities += slices.map { ["dev-entry": "/dev/\($0)"] as [String: Any] }
	return try PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
}

private func diskutilInfoPlist(mountPoint: String?) throws -> Data {
	var dictionary: [String: Any] = [:]
	if let mountPoint {
		dictionary["MountPoint"] = mountPoint
	}
	return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

/// disk8 上有 System+Data 主 container → Data 卷 disk11s5。
private func apfsListPlist() throws -> Data {
	let guestMain: [String: Any] = [
		"PhysicalStores": [["DeviceIdentifier": "disk8s2"]],
		"Volumes": [
			["DeviceIdentifier": "disk11s1", "Roles": ["System"]],
			["DeviceIdentifier": "disk11s5", "Roles": ["Data"]]
		]
	]
	return try PropertyListSerialization.data(fromPropertyList: ["Containers": [guestMain]], format: .xml, options: 0)
}

private func makeTempDiskImage() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(path: "gvm-\(UUID().uuidString).img")
	try Data().write(to: url)
	return url
}

private func busyFailure() -> Result<Data, any Error> {
	.failure(CommandRunnerError.commandFailed(
		executable: "/usr/bin/hdiutil",
		status: 1,
		stderr: "hdiutil: attach failed - Resource busy"
	))
}

private func captureMounterError(_ body: () async throws -> Void) async -> MacGuestVolumeMounterError? {
	do {
		try await body()
		return nil
	} catch let error as MacGuestVolumeMounterError {
		return error
	} catch {
		// 型別不對就地記下——否則呼叫端只看到 nil，看不出漏出來的是什麼（錯誤契約
		// 轉譯回歸時，那正是唯一想診斷的事）。
		Issue.record("預期 MacGuestVolumeMounterError、得 \(error)")
		return nil
	}
}

// MARK: - MacGuestVolumeMounterTests

private final class MacGuestVolumeMounterTests {

	/// 跨呼叫安全的計數器（給「前 N 次 busy 後成功」這類腳本）。
	private final class Counter: @unchecked Sendable {

		func next() -> Int {
			lock.lock()
			defer { lock.unlock() }
			let current = value
			value += 1
			return current
		}

		private let lock: NSLock = .init()

		private var value = 0
	}

	@Test
	private func `parse attach base disk extracts whole disk`() throws {
		let data = try hdiutilAttachPlist(wholeDisk: "disk8", slices: ["disk8s1", "disk8s2", "disk8s3"])
		#expect(try MacGuestVolumeMounter.parseAttachBaseDisk(data) == "disk8")
	}

	@Test
	private func `parse attach base disk throws when no whole disk`() throws {
		let slicesOnly = try PropertyListSerialization.data(
			fromPropertyList: ["system-entities": [["dev-entry": "/dev/disk8s2"]]],
			format: .xml,
			options: 0
		)
		do {
			_ = try MacGuestVolumeMounter.parseAttachBaseDisk(slicesOnly)
			Issue.record("預期擲 unparseableAttachOutput")
		} catch let error as MacGuestVolumeMounterError {
			guard case .unparseableAttachOutput = error else {
				Issue.record("預期 .unparseableAttachOutput、得 \(error)")
				return
			}
		}
	}

	@Test
	private func `parse mount point extracts point`() throws {
		let data = try diskutilInfoPlist(mountPoint: "/Volumes/Data")
		#expect(try MacGuestVolumeMounter.parseMountPoint(data) == "/Volumes/Data")
	}

	@Test
	private func `parse mount point throws when absent`() throws {
		let data = try diskutilInfoPlist(mountPoint: nil)
		do {
			_ = try MacGuestVolumeMounter.parseMountPoint(data)
			Issue.record("預期擲 notReady")
		} catch let error as MacGuestVolumeMounterError {
			guard case .notReady = error else {
				Issue.record("預期 .notReady、得 \(error)")
				return
			}
		}
	}

	/// happy path：attach→locate→mount→detach 回正確值、下的命令正確。
	@Test
	private func `attach locate mount detach happy path`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let attachPlist = try hdiutilAttachPlist(wholeDisk: "disk8", slices: ["disk8s1", "disk8s2", "disk8s3"])
		let apfsPlist = try apfsListPlist()
		let infoPlist = try diskutilInfoPlist(mountPoint: "/Volumes/Data")
		let fake = FakeCommandRunner { executable, arguments in
			if executable.hasSuffix("hdiutil"), arguments.first == "attach" {
				return .success(attachPlist)
			}
			if executable.hasSuffix("diskutil"), arguments.first == "apfs" {
				return .success(apfsPlist)
			}
			if executable.hasSuffix("diskutil"), arguments.first == "info" {
				return .success(infoPlist)
			}
			return .success(Data())
		}
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		#expect(try await mounter.attach() == "disk8")
		#expect(try await mounter.locateDataVolume() == "disk11s5")
		#expect(try await mounter.mount().path == "/Volumes/Data")
		try await mounter.detach()

		let calls = fake.calls
		#expect(calls.contains {
			$0.executable.hasSuffix("hdiutil") && $0.arguments == ["attach", "-nomount", "-owners", "on", "-plist", image.path]
		})
		#expect(calls.contains { $0.arguments == ["apfs", "list", "-plist"] })
		#expect(calls.contains { $0.arguments == ["mount", "-mountOptions", "nobrowse", "disk11s5"] })
		#expect(calls.contains { $0.arguments == ["detach", "/dev/disk8"] })
	}

	@Test
	private func `attach retries on busy then succeeds`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let attachPlist = try hdiutilAttachPlist(wholeDisk: "disk8", slices: [])
		let attempts: Counter = .init()
		let fake = FakeCommandRunner { executable, arguments in
			if executable.hasSuffix("hdiutil"), arguments.first == "attach" {
				return attempts.next() < 2 ? busyFailure() : .success(attachPlist)
			}
			return .success(Data())
		}
		let mounter: MacGuestVolumeMounter = .init(
			diskImage: image,
			runner: fake,
			retryBaseDelayMilliseconds: 1,
			retryCapMilliseconds: 2000
		)
		#expect(try await mounter.attach() == "disk8")
		#expect(fake.calls.count(where: { $0.arguments.first == "attach" }) == 3)
	}

	@Test
	private func `attach throws still busy after cap`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let fake = FakeCommandRunner { _, arguments in
			arguments.first == "attach" ? busyFailure() : .success(Data())
		}
		let mounter: MacGuestVolumeMounter = .init(
			diskImage: image,
			runner: fake,
			retryBaseDelayMilliseconds: 1,
			retryCapMilliseconds: 5
		)
		let error = await captureMounterError { _ = try await mounter.attach() }
		guard case .stillBusy = error else {
			Issue.record("預期 .stillBusy、得 \(String(describing: error))")
			return
		}
	}

	@Test
	private func `mount maps locked failure to encrypted locked`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let attachPlist = try hdiutilAttachPlist(wholeDisk: "disk8", slices: ["disk8s2"])
		let apfsPlist = try apfsListPlist()
		let fake = FakeCommandRunner { executable, arguments in
			if arguments.first == "attach" {
				return .success(attachPlist)
			}
			if arguments.first == "apfs" {
				return .success(apfsPlist)
			}
			if arguments.first == "mount" {
				return .failure(CommandRunnerError.commandFailed(
					executable: executable,
					status: 66,
					stderr: "Volume on disk11s5 is locked"
				))
			}
			return .success(Data())
		}
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		_ = try await mounter.attach()
		_ = try await mounter.locateDataVolume()
		let error = await captureMounterError { _ = try await mounter.mount() }
		guard case .encryptedLocked = error else {
			Issue.record("預期 .encryptedLocked、得 \(String(describing: error))")
			return
		}
	}

	/// 釘住錯誤契約轉譯：runner 擲通用 ``CommandRunnerError``、本型別對外擲自己的
	/// ``MacGuestVolumeMounterError/commandFailed(executable:status:stderr:)``，三個欄位逐項保真。
	/// 轉譯漏掉時 `captureMounterError` 會收不到（回 nil）而失敗。
	@Test
	private func `command failure surfaces as mounter error`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let fake = FakeCommandRunner { executable, _ in
			.failure(CommandRunnerError.commandFailed(
				executable: executable,
				status: 12,
				stderr: "hdiutil: attach failed - no mountable file systems"
			))
		}
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		let error = await captureMounterError { _ = try await mounter.attach() }
		guard case let .commandFailed(executable, status, stderr) = error else {
			Issue.record("預期 .commandFailed、得 \(String(describing: error))")
			return
		}
		#expect(executable == "/usr/bin/hdiutil")
		#expect(status == 12)
		#expect(stderr == "hdiutil: attach failed - no mountable file systems")
	}

	@Test
	private func `locate before attach throws not ready`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let fake = FakeCommandRunner { _, _ in .success(Data()) }
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		let error = await captureMounterError { _ = try await mounter.locateDataVolume() }
		guard case .notReady = error else {
			Issue.record("預期 .notReady、得 \(String(describing: error))")
			return
		}
		#expect(fake.calls.isEmpty)
	}

	@Test
	private func `detach without attach is noop`() async throws {
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let fake = FakeCommandRunner { _, _ in .success(Data()) }
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		try await mounter.detach()
		#expect(fake.calls.isEmpty)
	}

	/// 非 root 下 enableOwnership / write preflight 即擋（不必先 attach）。
	@Test
	private func `root steps require root`() async throws {
		try #require(geteuid() != 0, "本測試假設非 root 執行環境")
		let image = try makeTempDiskImage()
		defer { try? FileManager.default.removeItem(at: image) }
		let fake = FakeCommandRunner { _, _ in .success(Data()) }
		let mounter: MacGuestVolumeMounter = .init(diskImage: image, runner: fake)
		let ownershipError = await captureMounterError { try await mounter.enableOwnership() }
		guard case .requiresRoot = ownershipError else {
			Issue.record("enableOwnership 預期 .requiresRoot、得 \(String(describing: ownershipError))")
			return
		}
		let writeError = await captureMounterError { try await mounter.write([]) }
		guard case .requiresRoot = writeError else {
			Issue.record("write 預期 .requiresRoot、得 \(String(describing: writeError))")
			return
		}
		#expect(fake.calls.isEmpty)
	}
}
