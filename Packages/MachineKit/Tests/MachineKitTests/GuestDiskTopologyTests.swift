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

/// 從 (physStore, [(volumeID, roles)]) 組一個 `diskutil apfs list -plist` 的 container dict。
private func apfsContainer(physStore: String, volumes: [(id: String, roles: [String])]) -> [String: Any] {
	[
		"PhysicalStores": [["DeviceIdentifier": physStore]],
		"Volumes": volumes.map { ["DeviceIdentifier": $0.id, "Roles": $0.roles] as [String: Any] }
	]
}

/// 把 container dict 陣列包成根層、序列化成 plist bytes、餵 `GuestDiskTopology`。
private func makeTopology(_ containers: [[String: Any]]) throws -> GuestDiskTopology {
	let root: [String: Any] = ["Containers": containers]
	let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
	return try GuestDiskTopology(plistData: data)
}

/// 跑 body、攔下 ``GuestVolumeMounterError`` 供 case 比對（error 含 associated value、
/// 不便走 `#expect(throws:)` 的相等比對）。
private func captureError(_ body: () throws -> Void) -> GuestVolumeMounterError? {
	do {
		try body()
		return nil
	} catch let error as GuestVolumeMounterError {
		return error
	} catch {
		return nil
	}
}

// MARK: - GuestDiskTopologyTests

private final class GuestDiskTopologyTests {

	/// 安全命脈：同一份 topology 裡 host 自己的 Data 卷（`disk3s1`）也在場，查 attached
	/// `disk8` 必須回 guest 的 `disk11s5`、**絕不**回 host 卷。
	@Test
	private func `picks guest data volume never host data volume`() throws {
		let hostMain = apfsContainer(physStore: "disk0s2", volumes: [
			("disk3s1", ["Data"]),
			("disk3s3", ["System"]),
			("disk3s4", ["Preboot"]),
			("disk3s5", ["Recovery"])
		])
		let guestISC = apfsContainer(physStore: "disk8s1", volumes: [
			("disk9s1", ["Preboot"]),
			("disk9s2", ["xART"])
		])
		let guestRecovery = apfsContainer(physStore: "disk8s3", volumes: [
			("disk10s1", ["Recovery"])
		])
		let guestMain = apfsContainer(physStore: "disk8s2", volumes: [
			("disk11s1", ["System"]),
			("disk11s2", ["Preboot"]),
			("disk11s3", ["Recovery"]),
			("disk11s5", ["Data"])
		])
		let topology = try makeTopology([hostMain, guestISC, guestRecovery, guestMain])
		#expect(try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") == "disk11s5")
	}

	/// attached disk 上只有 iSC + Recovery container（皆無 System+Data）→ 不誤認成
	/// guest、擲 `noDataVolume`。
	@Test
	private func `ignores isc and recovery containers without system and data`() throws {
		let guestISC = apfsContainer(physStore: "disk8s1", volumes: [("disk9s1", ["Preboot"]), ("disk9s2", ["xART"])])
		let guestRecovery = apfsContainer(physStore: "disk8s3", volumes: [("disk10s1", ["Recovery"])])
		let topology = try makeTopology([guestISC, guestRecovery])
		let error = captureError { _ = try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") }
		guard case .noDataVolume = error else {
			Issue.record("預期 .noDataVolume、得 \(String(describing: error))")
			return
		}
	}

	/// attached disk 完全不在 topology 內（只有 host）→ `noDataVolume`、不退回掃 host。
	@Test
	private func `throws no data volume when attached disk absent`() throws {
		let hostMain = apfsContainer(physStore: "disk0s2", volumes: [("disk3s1", ["Data"]), ("disk3s3", ["System"])])
		let topology = try makeTopology([hostMain])
		let error = captureError { _ = try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") }
		guard case .noDataVolume = error else {
			Issue.record("預期 .noDataVolume、得 \(String(describing: error))")
			return
		}
	}

	/// attached disk 上有兩個 guest-like container（皆 System+Data）→ 拒絕猜、擲
	/// `ambiguousVolume`。
	@Test
	private func `throws ambiguous when two guest containers on attached disk`() throws {
		let one = apfsContainer(physStore: "disk8s2", volumes: [("disk11s1", ["System"]), ("disk11s5", ["Data"])])
		let two = apfsContainer(physStore: "disk8s4", volumes: [("disk12s1", ["System"]), ("disk12s5", ["Data"])])
		let topology = try makeTopology([one, two])
		let error = captureError { _ = try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") }
		guard case .ambiguousVolume = error else {
			Issue.record("預期 .ambiguousVolume、得 \(String(describing: error))")
			return
		}
	}

	/// 單一 guest container 內出現兩個 Data role 卷 → `ambiguousVolume`。
	@Test
	private func `throws ambiguous when container has two data volumes`() throws {
		let main = apfsContainer(physStore: "disk8s2", volumes: [
			("disk11s1", ["System"]),
			("disk11s5", ["Data"]),
			("disk11s6", ["Data"])
		])
		let topology = try makeTopology([main])
		let error = captureError { _ = try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") }
		guard case .ambiguousVolume = error else {
			Issue.record("預期 .ambiguousVolume、得 \(String(describing: error))")
			return
		}
	}

	/// 前綴比對安全：查 `disk8` 不可吃到另一顆盤 `disk80` 上的 guest-like container。
	@Test
	private func `base disk prefix does not over match sibling disk`() throws {
		let sibling = apfsContainer(physStore: "disk80s2", volumes: [("disk81s1", ["System"]), ("disk81s5", ["Data"])])
		let topology = try makeTopology([sibling])
		let error = captureError { _ = try topology.dataVolumeDeviceID(onAttachedDisk: "disk8") }
		guard case .noDataVolume = error else {
			Issue.record("預期 .noDataVolume（disk80 不該被 disk8 吃到）、得 \(String(describing: error))")
			return
		}
	}

	/// 非 plist / 結構不符的 bytes → `malformedTopology`。
	@Test
	private func `throws malformed topology on garbage bytes`() {
		let error = captureError { _ = try GuestDiskTopology(plistData: Data("not a plist".utf8)) }
		guard case .malformedTopology = error else {
			Issue.record("預期 .malformedTopology、得 \(String(describing: error))")
			return
		}
	}
}
