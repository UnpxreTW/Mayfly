//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// host 側離線掛載 / 注入 guest 卷時的錯誤。
///
/// 目前只涵蓋「找出 guest Data 卷」這條安全關鍵路徑（``GuestDiskTopology``）；
/// 實際 attach / mount / chown 的薄殼（需 root）落地時再補 `stillBusy` /
/// `encryptedLocked` / `requiresRoot` 等案例。
public enum GuestVolumeMounterError: Error {

	/// attached image 上找不到 macOS guest 的 Data 卷——非 macOS 映像、或 APFS
	/// 結構不含「同時具 System 與 Data role」的 container。
	case noDataVolume

	/// attached image 上出現多個 guest-like container、或單一 container 內多個 Data
	/// 卷。寧可拒絕也不猜——猜錯卷＝寫進非預期卷，是離線注入最不能犯的錯。
	case ambiguousVolume

	/// `diskutil apfs list -plist` 的輸出無法解碼成預期結構。
	case malformedTopology(underlying: any Error)
}
