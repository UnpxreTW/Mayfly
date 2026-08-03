//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Containerization
import Testing

// MARK: - LinuxContainerNetworkTests

private final class LinuxContainerNetworkTests {

	/// 每張介面都套用網路持有的 MTU，而非上游 `createInterface(_:)` 的預設 1500。
	@Test
	private func `applies the configured mtu to every interface`() throws {
		let allocator: FakeInterfaceAllocator = .init(addresses: ["192.168.64.2/24", "192.168.64.3/24"])
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		let first: (any Interface)? = try network.createInterface("alpha")
		let second: (any Interface)? = try network.createInterface("beta")
		#expect(first?.mtu == LinuxContainerNetwork.defaultMTU)
		#expect(second?.mtu == LinuxContainerNetwork.defaultMTU)
		#expect(allocator.makeCalls.allSatisfy { $0.mtu == LinuxContainerNetwork.defaultMTU })
	}

	/// MTU 預設值＝1400（裁定值；改動會連帶改變大封包路徑的行為，故以測試釘住）。
	@Test
	private func `defaults the mtu to the decided value`() {
		#expect(LinuxContainerNetwork.defaultMTU == 1400)
	}

	/// 配發狀態跨呼叫累積：兩個容器拿到相異位址，第二次不會重發第一個位址。
	@Test
	private func `hands out distinct addresses across calls`() throws {
		let allocator: FakeInterfaceAllocator = .init(addresses: ["192.168.64.2/24", "192.168.64.3/24"])
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		_ = try network.createInterface("alpha")
		_ = try network.createInterface("beta")
		#expect(network.ipv4Address(for: "alpha") == "192.168.64.2")
		#expect(network.ipv4Address(for: "beta") == "192.168.64.3")
	}

	/// 本型別存在的理由之一：位址對照表得跨持有者共用。每次 provision 各建一顆
	/// `ContainerManager`、以**值**持有網路——參照語義讓兩個持有者配出去的位址落在同一張表
	/// 上，``LinuxGuestControl`` 才查得到。若改回 struct，每個持有者只看得見自己配過的那幾筆。
	@Test
	private func `shares allocation state across value copies of its holder`() throws {
		let allocator: FakeInterfaceAllocator = .init(addresses: ["192.168.64.2/24", "192.168.64.3/24"])
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		var firstHolder: FakeNetworkHolder = .init(network: network)
		var secondHolder: FakeNetworkHolder = firstHolder
		try firstHolder.attach("alpha")
		try secondHolder.attach("beta")
		#expect(network.ipv4Address(for: "alpha") == "192.168.64.2")
		#expect(network.ipv4Address(for: "beta") == "192.168.64.3")
	}

	/// 併發配發不會發出重複位址。`LinuxGuestEngine.provision` 不在 `SessionStore` 的 actor
	/// 上執行，兩次 provision 真的會重疊——護住對照表的那把鎖是本型別最吃重的一段，直接壓。
	@Test
	private func `hands out distinct addresses under concurrent allocation`() async {
		let count: Int = 32
		let allocator: FakeInterfaceAllocator = .init(addresses: (0 ..< count).map { "192.168.64.\($0 + 2)/24" })
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		await withTaskGroup(of: Void.self) { group in
			for index in 0 ..< count {
				group.addTask { _ = try? network.createInterface("container-\(index)") }
			}
		}
		let issued: [String] = (0 ..< count).compactMap { network.ipv4Address(for: "container-\($0)") }
		#expect(issued.count == count)
		#expect(Set(issued).count == count)
	}

	/// 交還後位址查無，且配額回到來源網路可再配發。
	@Test
	private func `forgets the address once the interface is released`() throws {
		let allocator: FakeInterfaceAllocator = .init(addresses: ["192.168.64.2/24"])
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		_ = try network.createInterface("alpha")
		#expect(network.ipv4Address(for: "alpha") == "192.168.64.2")
		try network.releaseInterface("alpha")
		#expect(network.ipv4Address(for: "alpha") == nil)
		#expect(allocator.discardCalls == ["alpha"])
		_ = try network.createInterface("beta")
		#expect(network.ipv4Address(for: "beta") == "192.168.64.2")
	}

	/// 配額用盡走的是擲錯、不是回 `nil`（對齊真配發器的 `AllocatorError.allocatorFull`）：
	/// 錯誤一路傳回呼叫端，容器不會在沒有介面的狀態下被開起來，且不留下位址紀錄。
	@Test
	private func `propagates the exhaustion error from the source network`() {
		let network: LinuxContainerNetwork = .init(allocator: FakeInterfaceAllocator(addresses: []))
		#expect(throws: FakeInterfaceAllocator.Exhausted.self) {
			_ = try network.createInterface("alpha")
		}
		#expect(network.ipv4Address(for: "alpha") == nil)
	}

	/// 同一容器 id 配第二次即錯（對齊真配發器的 `ContainerizationError(.exists)`），
	/// 且第一次配到的位址不受影響。
	@Test
	private func `rejects a second interface for the same container`() throws {
		let allocator: FakeInterfaceAllocator = .init(addresses: ["192.168.64.2/24", "192.168.64.3/24"])
		let network: LinuxContainerNetwork = .init(allocator: allocator)
		_ = try network.createInterface("alpha")
		#expect(throws: FakeInterfaceAllocator.DuplicateAllocation.self) {
			_ = try network.createInterface("alpha")
		}
		#expect(network.ipv4Address(for: "alpha") == "192.168.64.2")
	}

	/// 來源網路若既不給介面也不擲錯，本型別就地擲錯、不把 `nil` 照傳上去——上游對 `nil`
	/// 是 `if let` 靜默跳過，容器會帶著 `networking: true` 開起來卻沒有介面也沒有錯誤。
	@Test
	private func `throws rather than handing a nil interface upstream`() {
		let network: LinuxContainerNetwork = .init(allocator: NilInterfaceAllocator())
		#expect(throws: LinuxContainerNetwork.AllocationError.self) {
			_ = try network.createInterface("alpha")
		}
		#expect(network.ipv4Address(for: "alpha") == nil)
	}

	/// 未配發過的容器 id 查無位址。
	@Test
	private func `reports no address for an unknown container`() {
		let network: LinuxContainerNetwork = .init(allocator: FakeInterfaceAllocator(addresses: ["192.168.64.2/24"]))
		#expect(network.ipv4Address(for: "never-provisioned") == nil)
	}
}

// MARK: - FakeNetworkHolder

/// 模擬 `ContainerManager` 的持有形狀：struct、以值持有網路、配發介面是 `mutating`。
/// 用來釘住「值複製後配發狀態仍共用」這條性質，不觸碰真的 `ContainerManager`。
private struct FakeNetworkHolder {

	var network: any Network

	mutating func attach(_ containerID: String) throws {
		_ = try network.createInterface(containerID)
	}
}
