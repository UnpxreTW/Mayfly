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
/// 涵蓋兩層：純識別核心 ``GuestDiskTopology``（`noDataVolume` / `ambiguousVolume` /
/// `malformedTopology`）＋ Process 薄殼 ``GuestVolumeMounter``（attach / mount /
/// enableOwnership / chown 的命令與生命週期錯誤）。
public enum GuestVolumeMounterError: Error {

	/// attached image 上找不到 macOS guest 的 Data 卷——非 macOS 映像、或 APFS
	/// 結構不含「同時具 System 與 Data role」的 container。
	case noDataVolume

	/// attached image 上出現多個 guest-like container、或單一 container 內多個 Data
	/// 卷。寧可拒絕也不猜——猜錯卷＝寫進非預期卷，是離線注入最不能犯的錯。
	case ambiguousVolume

	/// `diskutil apfs list -plist` 的輸出無法解碼成預期結構。
	case malformedTopology(underlying: any Error)

	/// 外部命令（hdiutil / diskutil / chown / chmod）非零 exit。
	case commandFailed(executable: String, status: Int32, stderr: String)

	/// install 後 VZ 仍持有 disk fd，attach 退避重試到上限仍 busy。
	case stillBusy

	/// guest Data 卷加密 / 鎖定、host 端無法 RW 掛載——觸發 Recovery fallback、非崩潰。
	case encryptedLocked

	/// 需 root 的步驟（`diskutil enableOwnership` / numeric `chown`）在非 root 下被呼叫。
	case requiresRoot

	/// `hdiutil attach -plist` 輸出解不出 GUID base disk。
	case unparseableAttachOutput

	/// 生命週期誤用：attach / locate / mount 尚未完成就呼叫依賴它的後續步驟。
	case notReady(step: String)

	/// 寫入某筆注入檔失敗。
	case writeFailed(relativePath: String, underlying: any Error)
}
