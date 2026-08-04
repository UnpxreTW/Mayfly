//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization

/// 配發／交還容器網路介面的最小面。
///
/// 為何不直接用 Containerization 的 `Network`：`Network` 要求的
/// `createInterface(_:)` 沒有 MTU 參數，帶 MTU 的只有 `VmnetNetwork` 上的具體多載
/// `createInterface(_:mtu:)`——套用自訂 MTU 就接不到協定面。本協定把「配一張帶指定
/// MTU 的介面」抽成可注入的接縫，讓 ``LinuxContainerNetwork`` 的共用語義與 MTU 政策
/// 能以假物件單測（測試環境開不了真的 vmnet 網路）。
protocol ContainerInterfaceAllocating: Sendable {

	/// 配一張介面給指定容器。
	///
	/// 回傳型別是 Optional 只為對上上游 `createInterface(_:mtu:)` 的簽名；`VmnetNetwork`
	/// 實際上不會回 `nil`——配額用盡與同一 id 重複配發都是擲錯。實作若真回 `nil`，
	/// ``LinuxContainerNetwork`` 會轉成 ``LinuxContainerNetwork/AllocationError`` 擲出，
	/// 不讓它一路傳到會靜默跳過的上游。
	/// - Parameters:
	///   - containerID: 容器 id。
	///   - mtu: 介面 MTU。
	/// - Returns: 配發到的介面。
	/// - Throws: 配額用盡或同一 id 重複配發。
	mutating func makeInterface(_ containerID: String, mtu: UInt32) throws -> (any Containerization.Interface)?

	/// 交還指定容器占用的位址配額。已交還或從未配發時為 no-op。
	/// - Parameter containerID: 容器 id。
	mutating func discardInterface(_ containerID: String) throws
}

extension VmnetNetwork: ContainerInterfaceAllocating {

	mutating func makeInterface(_ containerID: String, mtu: UInt32) throws -> (any Containerization.Interface)? {
		try createInterface(containerID, mtu: mtu)
	}

	mutating func discardInterface(_ containerID: String) throws {
		try releaseInterface(containerID)
	}
}
