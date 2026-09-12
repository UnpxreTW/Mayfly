//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 共用容器網路的持有者：第一次真的要用時才建，之後每次都回同一顆。
///
/// **為何是 lazy、不在 daemon 啟動時就建**：`vmnet` 建不起來（權限、環境、配額）時，
/// 啟動期建網會讓整支 daemon 起不來——連完全不碰 Linux 的 macOS session 一起停擺，
/// 而那是這台機器的臨界路徑。改成第一次 Linux spawn 才建，失敗就落在那一次 spawn 的
/// 回應上（`clone_failed`），影響面與肇因一致。
///
/// **為何要快取**：``LinuxContainerNetwork/vmnet(mtu:)`` 每呼叫一次就是一張獨立的網路
/// （各自的子網與位址表），整個引擎壽命內只該有一顆——理由見該型別的說明。
///
/// **失敗不快取**：工廠擲錯時不記任何狀態，下一次 spawn 會重試一次。網路建不起來多半是
/// 環境條件（權限授予、配額釋出）造成的，這類條件會在 daemon 存活期間變好；把第一次的
/// 失敗記起來，等於要求操作者重啟 daemon 才能復原。
///
/// 用鎖護 class（非 actor）：呼叫端 ``LinuxGuestEngine`` 在同步段取用，鎖只護住
/// 「檢查快取 → 建立 → 寫回」這段、不跨 `await` 持鎖（比照 ``LinuxContainerNetwork``
/// 的既有作法）。
public final class LinuxNetworkProvider: @unchecked Sendable {

	// MARK: Public

	/// 依模式建一個 provider。
	/// - Parameter mode: 網路模式；``LinuxNetworkMode/disabled`` 恆回 `nil`（不接網路）。
	public convenience init(mode: LinuxNetworkMode) {
		switch mode {
		case .vmnet:
			self.init(factory: { try LinuxContainerNetwork.vmnet() })

		case .disabled:
			self.init(factory: { nil })
		}
	}

	// MARK: Internal

	/// 以指定的工廠建一個 provider——正式路徑走上面的 ``init(mode:)``，本形供測試注入假工廠。
	/// - Parameter factory: 真正建網路的動作，正式路徑上是 vmnet。
	internal init(factory: @escaping @Sendable () throws -> LinuxContainerNetwork?) {
		self.factory = factory
	}

	/// 取共用網路：首次呼叫建立並記住，之後回同一顆。
	/// - Returns: 共用網路；模式為不接網路時回 `nil`。
	/// - Throws: 工廠擲出的錯誤，原樣往上傳（每次呼叫都會重試）。
	internal func network() throws -> LinuxContainerNetwork? {
		lock.lock()
		defer { lock.unlock() }
		if let cached: LinuxContainerNetwork = cached {
			return cached
		}
		let created: LinuxContainerNetwork? = try factory()
		cached = created
		return created
	}

	// MARK: Private

	/// 護住 `cached`：provider 是 class、可能同時被多個 session 的 provision 取用。
	private let lock: NSLock = .init()

	/// 真正建網路的那一步；回 `nil` 代表這個 provider 不接網路。
	private let factory: @Sendable () throws -> LinuxContainerNetwork?

	/// 已建好的那一顆；`nil` 代表還沒建、或這個 provider 本來就不接網路。
	private var cached: LinuxContainerNetwork?
}
