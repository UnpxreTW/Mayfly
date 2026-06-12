//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// guest 停止的原因。
public enum GuestStopReason: Sendable {

	/// guest 自行關機（guestDidStop）。
	case guestInitiated

	/// VM 因錯誤停止（didStopWithError）。
	case error(any Error)

	/// 因 ``MacGuest/forceStop()`` 或 ``MacGuest/ensureStopped(within:)``
	/// 的逾時 fallback 而硬停；等待中的 ``MacGuest/waitUntilStopped()``
	/// 也會以此收斂返回。
	case forced
}
