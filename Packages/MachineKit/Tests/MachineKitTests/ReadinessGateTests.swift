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

// MARK: - LeaseSequence

/// 前 nilCount 次回 nil、之後回 content——模擬 lease 比 marker 晚幾次輪詢才出現。
private final class LeaseSequence: @unchecked Sendable {

	init(nilCount: Int, then content: String) {
		self.nilCount = nilCount
		self.content = content
	}

	func next() -> String? {
		lock.withLock {
			guard calls >= nilCount else {
				calls += 1
				return nil
			}
			return content
		}
	}

	private let nilCount: Int

	private let content: String

	private var calls = 0

	private let lock: NSLock = .init()
}

private func makeLineStream(_ lines: [String]) -> AsyncStream<String> {
	AsyncStream { continuation in
		for line in lines {
			continuation.yield(line)
		}
		continuation.finish()
	}
}

private func collect(_ stream: AsyncStream<Readiness>) async -> [Readiness] {
	var received: [Readiness] = []
	for await readiness in stream {
		received.append(readiness)
	}
	return received
}

// MARK: - ReadinessGateTests

private final class ReadinessGateTests {

	@Test
	private func `parse marker extracts user and ip`() throws {
		let marker = try #require(ReadinessGate.parseMarker(line: "PROVISIONING_READY user=runner ip=192.168.64.5"))
		#expect(marker.user == "runner")
		#expect(marker.ip == "192.168.64.5")
	}

	/// ip=none → ip 解為 nil（en0 尚無位址）。
	@Test
	private func `parse marker maps none ip to nil`() throws {
		let marker = try #require(ReadinessGate.parseMarker(line: "PROVISIONING_READY user=runner ip=none"))
		#expect(marker.user == "runner")
		#expect(marker.ip == nil)
	}

	/// 容忍行首雜訊（console 常見時間戳 / 控制字元前綴）。
	@Test
	private func `parse marker tolerates leading noise`() throws {
		let marker = try #require(ReadinessGate.parseMarker(line: "[   12.345678] PROVISIONING_READY user=ci ip=10.0.0.9"))
		#expect(marker.user == "ci")
		#expect(marker.ip == "10.0.0.9")
	}

	@Test
	private func `parse marker returns nil for non marker line`() {
		#expect(ReadinessGate.parseMarker(line: "launchd: boot complete") == nil)
	}

	/// 有 marker token 但缺 user → nil（不完整訊號不採信）。
	@Test
	private func `parse marker returns nil when user missing`() {
		#expect(ReadinessGate.parseMarker(line: "PROVISIONING_READY ip=10.0.0.9") == nil)
	}

	/// 前導零正規化後 MAC byte-match → 回該區塊 IP。
	@Test
	private func `resolve lease ip matches normalized mac`() {
		#expect(ReadinessGate.resolveLeaseIP(fromLeases: leaseFixture, matching: "0a:1b:02:d4:e5:f6") == "192.168.64.7")
	}

	@Test
	private func `resolve lease ip returns nil for non matching mac`() {
		#expect(ReadinessGate.resolveLeaseIP(fromLeases: leaseFixture, matching: "aa:bb:cc:dd:ee:ff") == nil)
	}

	@Test
	private func `resolve lease ip returns nil for empty mac`() {
		#expect(ReadinessGate.resolveLeaseIP(fromLeases: leaseFixture, matching: "") == nil)
	}

	/// marker 帶 ip → 直接用、不碰 lease；流為 booting → provisioningReady(ip)。
	@Test
	private func `readiness emits ready from marker ip`() async {
		let gate: ReadinessGate = .init(macAddress: nil, readLeases: { nil })
		let stream = gate.readiness(consoleLines: makeLineStream(["PROVISIONING_READY user=runner ip=192.168.64.5"]))
		#expect(await collect(stream) == [.booting, .provisioningReady(ip: "192.168.64.5")])
	}

	/// marker ip=none → 走 lease 備援、以注入 MAC 解出 IP。
	@Test
	private func `readiness falls back to lease when ip none`() async {
		let gate: ReadinessGate = .init(macAddress: "0a:1b:02:d4:e5:f6", readLeases: { leaseFixture })
		let stream = gate.readiness(consoleLines: makeLineStream(["PROVISIONING_READY user=runner ip=none"]))
		#expect(await collect(stream) == [.booting, .provisioningReady(ip: "192.168.64.7")])
	}

	/// 無 marker → 只發 booting 後結束（沒有偽 ready）。
	@Test
	private func `readiness stays booting without marker`() async {
		let gate: ReadinessGate = .init(macAddress: nil, readLeases: { nil })
		let stream = gate.readiness(consoleLines: makeLineStream(["boot log line", "another line"]))
		#expect(await collect(stream) == [.booting])
	}

	/// marker ip=none + lease 晚幾次輪詢才出現 → 輪詢到解出 IP（不讀一次就放棄）。
	@Test
	private func `readiness polls lease until it appears`() async {
		let sequence: LeaseSequence = .init(nilCount: 2, then: leaseFixture)
		let gate: ReadinessGate = .init(
			macAddress: "0a:1b:02:d4:e5:f6",
			readLeases: { sequence.next() },
			leaseResolvePollMilliseconds: 1,
			leaseResolveTimeoutMilliseconds: 1000
		)
		let stream = gate.readiness(consoleLines: makeLineStream(["PROVISIONING_READY user=runner ip=none"]))
		#expect(await collect(stream) == [.booting, .provisioningReady(ip: "192.168.64.7")])
	}

	/// marker ip=none + lease 逾時仍未出現 → best-effort 回 provisioningReady(ip: nil)。
	@Test
	private func `readiness reports nil ip when lease never resolves`() async {
		let gate: ReadinessGate = .init(
			macAddress: "0a:1b:02:d4:e5:f6",
			readLeases: { nil },
			leaseResolvePollMilliseconds: 1,
			leaseResolveTimeoutMilliseconds: 5
		)
		let stream = gate.readiness(consoleLines: makeLineStream(["PROVISIONING_READY user=runner ip=none"]))
		#expect(await collect(stream) == [.booting, .provisioningReady(ip: nil)])
	}

	/// 非法 hex 段的 MAC → 視為無效、回 nil（不做掉段後的部分比對）。
	@Test
	private func `resolve lease ip rejects malformed mac`() {
		#expect(ReadinessGate.resolveLeaseIP(fromLeases: leaseFixture, matching: "0a:1b:zz:d4:e5:f6") == nil)
	}
}
