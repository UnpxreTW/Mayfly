//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// ``GuestProvisioner`` 的錯誤。多數失敗由 ``GuestVolumeMounter`` 的
/// ``GuestVolumeMounterError`` 直接上拋；此型別只收 P4 層自有的決策訊號。
public enum GuestProvisionerError: Error, Sendable {

	/// 掛載回報加密 / 鎖定（``GuestVolumeMounterError/encryptedLocked``）——離線注入此路
	/// 不通，需改走 Recovery fallback（P6、尚未建）。P4 在此留 seam、不自行提權解鎖。
	case requiresRecoveryFallback
}
