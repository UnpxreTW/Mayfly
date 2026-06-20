//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// macOS guest CREATE 路徑（安裝）的錯誤。細分到「哪一步壞」便於呼叫端決策
/// （重抓 image / 重建 bundle / 放棄）。VZ 層的 install 失敗原樣上拋 `VZError`。
public enum MacGuestInstallerError: Error {

	/// bundle 目錄已存在、且未要求覆寫——保護裝好的 guest 不被覆掉。
	case bundleAlreadyExists(URL)

	/// restore image 的硬體模型這台 host 跑不動（`isSupported` 為 false）。
	case hardwareModelUnsupported

	/// image 的最低 cpu / 記憶體要求超出這台 host 的允許上限——不以 under-spec
	/// 設定 install（低於最低是 undefined behavior）。
	case resourceRequirementsExceedHost

	/// install 成功後寫身份檔 / metadata 失敗；`url` 是寫失敗的目標。
	case identityWriteFailed(URL, underlying: any Error)

	/// install 被 Task 取消。
	case cancelled

	/// installer 已用過（一次性、install 已收束）——別重用、另建一台。
	case alreadyConsumed
}
