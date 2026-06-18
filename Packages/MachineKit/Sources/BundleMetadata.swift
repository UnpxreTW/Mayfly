//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// guest bundle 的稽核 / 重建資訊，落地成 bundle 內的 `metadata.json`。
///
/// 固定 MAC 存這裡而非獨立檔：``MacGuestSpec/macAddress`` 是 `String?`、屬執行
/// 參數面，但對 CREATE 出來的 guest 它是烤進身份的固定值，需與 disk / aux 一起
/// 持久化才能跨重開機保住同一 DHCP lease。OS 版本與 ipsw sha256 純供稽核與
/// 「來源是否變動」判定、開機不需要。
///
/// **演進規則**：日後加欄位一律用 Optional 或給 decode 預設，否則舊 bundle 的
/// `metadata.json` 會在新版 decode 失敗（未知欄位則向後相容、會被忽略）。
public struct BundleMetadata: Codable, Sendable {

	/// 固定 locally-administered MAC（`02:` 開頭）。跨重開機保 DHCP lease、
	/// 屬 guest 身份的一部分。
	public var macAddress: String

	/// 安裝來源的 OS build version（如 `VZMacOSRestoreImage.buildVersion`）。
	public var osBuildVersion: String

	/// 安裝來源的 OS 版本字串。
	public var osVersion: String

	/// 安裝所用 `.ipsw` 的 SHA256，供稽核與偵測來源變動。
	public var restoreImageSHA256: String

	public init(
		macAddress: String,
		osBuildVersion: String,
		osVersion: String,
		restoreImageSHA256: String
	) {
		self.macAddress = macAddress
		self.osBuildVersion = osBuildVersion
		self.osVersion = osVersion
		self.restoreImageSHA256 = restoreImageSHA256
	}
}
