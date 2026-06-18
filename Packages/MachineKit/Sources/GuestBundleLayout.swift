//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 身份原子 `.bundle` 目錄的布局——CREATE 寫入位置與 LOAD 讀取位置的單一
/// 事實來源。五件一綁（disk + aux + machineIdentifier + hardwareModel +
/// metadata 內的 MAC）落地成單一目錄，整包是 clonefile / mv / 刪除的原子單位。
///
/// 刻意做成 enum namespace 而非塞進 ``MacGuestSpec``：spec 純 Foundation、欄位是
/// 「持久狀態檔位置」、不該知道 bundle 封裝慣例；bundle 是 installer / CLI 層的
/// 約定。builder 的 LOAD 路徑透過 ``spec(for:metadata:cpuCount:memoryBytes:display:)``
/// 取得可直接餵的 spec，寫端與讀端不會漂移。
public enum GuestBundleLayout {

	/// 主磁碟（RAW sparse）。
	public static let diskImageName = "disk.img"

	/// 輔助儲存（aux storage、NVRAM 類比）。
	public static let auxiliaryStorageName = "auxiliaryStorage"

	/// 機器識別碼的 `dataRepresentation`。
	public static let machineIdentifierName = "machineIdentifier.bin"

	/// 硬體模型的 `dataRepresentation`。
	public static let hardwareModelName = "hardwareModel.bin"

	/// 建立資訊（固定 MAC、OS build / version、ipsw sha256）。
	public static let metadataName = "metadata.json"

	/// bundle 內主磁碟的位置。
	public static func diskImage(in bundle: URL) -> URL {
		bundle.appending(component: diskImageName)
	}

	/// bundle 內輔助儲存（aux storage）的位置。
	public static func auxiliaryStorage(in bundle: URL) -> URL {
		bundle.appending(component: auxiliaryStorageName)
	}

	/// bundle 內機器識別碼檔的位置。
	public static func machineIdentifier(in bundle: URL) -> URL {
		bundle.appending(component: machineIdentifierName)
	}

	/// bundle 內硬體模型檔的位置。
	public static func hardwareModel(in bundle: URL) -> URL {
		bundle.appending(component: hardwareModelName)
	}

	/// bundle 內建立資訊檔的位置。
	public static func metadata(in bundle: URL) -> URL {
		bundle.appending(component: metadataName)
	}

	/// 從 bundle 內檔位置與已讀的 `metadata` 組一份可直接餵 builder LOAD 路徑的
	/// spec：四個 URL 欄位指進 bundle、MAC 取自 metadata。CREATE 完成後 installer
	/// 用它回傳；CLI 開機既有 bundle 也走這條。`cpuCount` / `memoryBytes` /
	/// `display` 是每次執行參數、不存 bundle，由呼叫端給。
	public static func spec(
		for bundle: URL,
		metadata: BundleMetadata,
		cpuCount: Int,
		memoryBytes: UInt64,
		display: MacGuestSpec.Display = .init()
	) -> MacGuestSpec {
		MacGuestSpec(
			diskImage: diskImage(in: bundle),
			auxiliaryStorage: auxiliaryStorage(in: bundle),
			machineIdentifier: machineIdentifier(in: bundle),
			hardwareModel: hardwareModel(in: bundle),
			cpuCount: cpuCount,
			memoryBytes: memoryBytes,
			display: display,
			macAddress: metadata.macAddress
		)
	}
}
