//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Testing

// MARK: - LinuxNetworkProviderTests

private final class LinuxNetworkProviderTests {

	/// 不接網路的模式恆回 nil——`--linux-network none` 的行為與接線前完全相同。
	@Test
	private func `disabled mode never hands out a network`() throws {
		let provider: LinuxNetworkProvider = .init(mode: .disabled)
		let first: LinuxContainerNetwork? = try provider.network()
		let second: LinuxContainerNetwork? = try provider.network()
		#expect(first == nil)
		#expect(second == nil)
	}

	/// 只建一顆、之後回同一顆：容器散在互不相通的子網、位址表各記各的，都源自多建了網路。
	@Test
	private func `builds the network once and reuses it`() throws {
		let factory: RecordingNetworkFactory = .init()
		let provider: LinuxNetworkProvider = .init(factory: factory.make)
		let first: LinuxContainerNetwork? = try provider.network()
		let second: LinuxContainerNetwork? = try provider.network()
		#expect(first === second)
		#expect(first != nil)
		#expect(factory.calls == 1)
	}

	/// 建立時機是首次取用、不是 provider 生出來的當下——啟動期不該碰 vmnet。
	@Test
	private func `defers building until the network is first requested`() {
		let factory: RecordingNetworkFactory = .init()
		_ = LinuxNetworkProvider(factory: factory.make)
		#expect(factory.calls == 0)
	}

	/// 失敗不快取：每次取用都重試一次、每次都擲錯。環境條件（權限、配額）會在 daemon
	/// 存活期間變好，把第一次的失敗記起來等於逼操作者重啟 daemon。
	@Test
	private func `retries and rethrows when the factory keeps failing`() {
		let factory: RecordingNetworkFactory = .init(alwaysFails: true)
		let provider: LinuxNetworkProvider = .init(factory: factory.make)
		#expect(throws: RecordingNetworkFactory.Failure.unavailable) { try provider.network() }
		#expect(throws: RecordingNetworkFactory.Failure.unavailable) { try provider.network() }
		#expect(factory.calls == 2)
	}

	/// 對外字面值：`--linux-network` 收的是 `vmnet` 與 `none`（case 名 `disabled` 不外露）。
	@Test
	private func `spells the disabled case none on the command line`() {
		#expect(LinuxNetworkMode.disabled.rawValue == "none")
		#expect(LinuxNetworkMode.vmnet.rawValue == "vmnet")
		#expect(LinuxNetworkMode.allCases.map(\.rawValue) == ["vmnet", "none"])
	}
}

// MARK: - RecordingNetworkFactory

/// 假網路工廠：記呼叫次數、可配成每次擲錯——用來驗「只建一顆」與「失敗不快取」。
private final class RecordingNetworkFactory: @unchecked Sendable {

	// MARK: Internal

	/// 工廠失敗時擲出的錯誤。
	internal enum Failure: Error, Equatable {

		/// 網路建不起來（對應真路徑上 vmnet 開不起來）。
		case unavailable
	}

	/// 逐欄建立。
	/// - Parameter alwaysFails: 為真時每次呼叫都擲 ``Failure/unavailable``。
	internal init(alwaysFails: Bool = false) {
		self.alwaysFails = alwaysFails
	}

	/// 目前為止被呼叫的次數。
	internal private(set) var calls: Int = 0

	/// 交給 ``LinuxNetworkProvider`` 的工廠：計數後回一顆新網路，或依設定擲錯。
	internal func make() throws -> LinuxContainerNetwork? {
		calls += 1
		if alwaysFails {
			throw Failure.unavailable
		}
		return .init(allocator: FakeInterfaceAllocator(addresses: ["192.168.64.2/24"]))
	}

	// MARK: Private

	/// 為真時工廠不回網路、只擲錯。
	private let alwaysFails: Bool
}
