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

/// dhcpd_leases 樣本：hw_address 省略前導零（`a:1b:2` == canonical `0a:1b:02`）。
private let leaseFixture = """
	{
		name=guest
		ip_address=192.168.64.7
		hw_address=1,a:1b:2:d4:e5:f6
		identifier=1,a:1b:2:d4:e5:f6
		lease=0x64abc123
	}
	"""

// MARK: - GuestLeaseTests

private final class GuestLeaseTests {

	/// 前導零正規化後 MAC byte-match → 回該區塊 IP。
	@Test
	private func `resolve ip matches normalized mac`() {
		#expect(GuestLease.resolveIP(fromLeases: leaseFixture, matching: "0a:1b:02:d4:e5:f6") == "192.168.64.7")
	}

	@Test
	private func `resolve ip returns nil for non matching mac`() {
		#expect(GuestLease.resolveIP(fromLeases: leaseFixture, matching: "aa:bb:cc:dd:ee:ff") == nil)
	}

	@Test
	private func `resolve ip returns nil for empty mac`() {
		#expect(GuestLease.resolveIP(fromLeases: leaseFixture, matching: "") == nil)
	}

	/// 非法 hex 段的 MAC → 視為無效、回 nil（不做掉段後的部分比對）。
	@Test
	private func `resolve ip rejects malformed mac`() {
		#expect(GuestLease.resolveIP(fromLeases: leaseFixture, matching: "0a:1b:zz:d4:e5:f6") == nil)
	}

	/// currentIP 快照：讀指定 lease 檔、命中回 IP。
	@Test
	private func `current ip reads leases file`() throws {
		let file: URL = FileManager.default
			.temporaryDirectory
			.appending(component: "GuestLeaseTests-\(UUID().uuidString).leases")
		defer { try? FileManager.default.removeItem(at: file) }
		try Data(leaseFixture.utf8).write(to: file)
		#expect(GuestLease.currentIP(macAddress: "0a:1b:02:d4:e5:f6", leasesFile: file) == "192.168.64.7")
	}

	/// lease 檔不存在 / 不可讀 → nil（不擲錯——查詢是 best-effort 快照）。
	@Test
	private func `current ip returns nil when leases file missing`() {
		let missing: URL = .init(fileURLWithPath: "/nonexistent/GuestLeaseTests.leases")
		#expect(GuestLease.currentIP(macAddress: "0a:1b:02:d4:e5:f6", leasesFile: missing) == nil)
	}
}
