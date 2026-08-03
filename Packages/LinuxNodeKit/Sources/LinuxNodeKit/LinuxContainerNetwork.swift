//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation

/// 整個引擎壽命內共用的一顆容器網路。
///
/// **為何需要這層、而不是把 `VmnetNetwork` 直接交給 `ContainerManager`**：有兩件事在協定面
/// 接不到。其一是 MTU——`ContainerManager` 只呼叫 `Network` 協定的 `createInterface(_:)`，
/// 帶 MTU 的是 `VmnetNetwork` 上的具體多載 `createInterface(_:mtu:)`，不包一層就完全套不上
/// （見 ``defaultMTU``）。其二是位址對照表——`ContainerManager` 是 struct、以**值**持有它的
/// `network`，而 ``LinuxGuestEngine`` 每次 provision 各建一顆 manager；對照表若隨值複製，
/// 每顆 manager 只記得自己配過的那幾筆，``LinuxGuestControl`` 讀到的會是一張空表、
/// `currentIP()` 恆為 `nil`。本型別是 class：manager 複製的是參照，對照表於是真的跨 manager、
/// 跨 provision 共用。
///
/// **不是**為了避免兩個容器配到同一個位址——位址唯一性由上游保證：`VmnetNetwork` 的 IPv4
/// index 配發器本身是 class（free list 由它自己的鎖護），值複製只複製 id → index 的紀錄、
/// free list 仍是同一條，副本之間配出來的位址本就相異。
///
/// 用鎖護 class（非 actor）：`Network` 的要求是同步方法，actor isolated 方法無法滿足；
/// 鎖只護住對照表本身的同步存取、不跨 `await` 持鎖（比照 ``LinuxGuestControl`` 的既有作法）。
public final class LinuxContainerNetwork: Network, @unchecked Sendable {

	// MARK: Public

	/// 配發介面的失敗面。
	public enum AllocationError: Error {

		/// 來源網路既沒回傳介面、也沒擲錯。上游 `createInterface` 的簽名雖是 Optional，
		/// 正式實作（`VmnetNetwork`）在配額用盡與 id 重複時都是**擲錯**、不回 `nil`；真收到
		/// `nil` 代表換上了語義不同的實作，此時必須擲錯而不是照傳——`nil` 一路上去會被
		/// `ContainerManager` 的 `if let` 靜默跳過，容器帶著 `networking: true` 開起來卻沒有
		/// 介面、沒有 DNS、也沒有任何錯誤。
		case interfaceUnavailable(containerID: String)
	}

	/// 容器介面 MTU。
	///
	/// **防的是什麼**：大封包在路徑上被靜默丟棄——交握與小回應一切正常，一抓大檔或大回應
	/// 就整條連線停住不動、最後逾時。症狀看起來像對端掛掉，最難歸因的一種網路故障。
	/// **為什麼是這個值**：路徑上某一段的 MTU 比來源小時，本該回來的 ICMP
	/// fragmentation-needed 常被中途的防火牆擋掉，來源永遠等不到「請縮小」的通知，於是一直
	/// 重送同樣過不去的大封包（PMTU 黑洞）。1400 落在常見隧道／VPN 封裝後的可用上限之內，
	/// 不必依賴那則 ICMP 能回得來。
	/// **代價**：每個封包少約 7% 酬載，同樣的資料量要多送幾個封包、吞吐略降——換掉的是
	/// 「只有大封包會壞」這種難以歸因的斷線。
	/// **佐證**：上游 `examples/sandboxy` 同樣把 vmnet 介面 MTU 由 1500 降到 1400，給的理由
	/// 也是避開會擋掉 ICMP fragmentation-needed 的網路上的 PMTU 黑洞。
	public static let defaultMTU: UInt32 = 1400

	/// 開一顆 vmnet 共享網路。
	///
	/// 每呼叫一次就是一張獨立的網路——各自的 `vmnet_network_ref`、各自的子網、各自一份位址
	/// 配發表——整個引擎壽命內只該開一顆。故刻意做成顯式呼叫、不藏進 ``LinuxGuestEngine``
	/// 的 init：否則每建一顆引擎就會悄悄多開一張網路，容器散落在互不相通的子網裡，而那是個
	/// 要到兩個容器彼此連不到才會發現的錯。
	/// - Parameter mtu: 介面 MTU，預設 ``defaultMTU``。
	/// - Returns: 可交給 ``LinuxGuestEngine`` 的共用網路。
	public static func vmnet(mtu: UInt32 = LinuxContainerNetwork.defaultMTU) throws -> LinuxContainerNetwork {
		let network: VmnetNetwork = try .init()
		return .init(allocator: network, mtu: mtu)
	}

	public func createInterface(_ containerID: String) throws -> (any Interface)? {
		try withLock {
			guard let interface: any Interface = try allocator.makeInterface(containerID, mtu: mtu) else {
				throw AllocationError.interfaceUnavailable(containerID: containerID)
			}
			addresses[containerID] = interface.ipv4Address.address.description
			return interface
		}
	}

	public func releaseInterface(_ containerID: String) throws {
		try withLock {
			// 先落掉紀錄再交還配額：交還若擲錯，留著一筆早已無效的位址只會讓上層回報
			// 一個不存在的 IP——寧可查無。
			addresses[containerID] = nil
			try allocator.discardInterface(containerID)
		}
	}

	// MARK: Internal

	/// - Parameters:
	///   - allocator: 實際配發位址的網路，正式路徑上是 `VmnetNetwork`、測試注入假物件。
	///   - mtu: 介面 MTU。
	init(allocator: any ContainerInterfaceAllocating, mtu: UInt32 = LinuxContainerNetwork.defaultMTU) {
		self.allocator = allocator
		self.mtu = mtu
	}

	/// 查指定容器目前配到的 IPv4 位址（點分十進位、不含前綴長度）。
	///
	/// 位址在配發介面的當下記下，不向 guest 內部查詢——因此 boot 尚未完成時即可回報。
	/// - Parameter containerID: 容器 id。
	/// - Returns: 已配發的位址；未配發或已交還時回 `nil`。
	func ipv4Address(for containerID: String) -> String? {
		withLock { addresses[containerID] }
	}

	// MARK: Private

	private let lock: NSLock = .init()

	private var allocator: any ContainerInterfaceAllocating

	private let mtu: UInt32

	/// 容器 id → 已配發的 IPv4 位址（點分十進位）。
	private var addresses: [String: String] = [:]

	private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}
}
