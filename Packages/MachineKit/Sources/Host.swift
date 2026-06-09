//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Virtualization

/// 主機虛擬化能力的查詢入口。
public enum Host {

	/// 這台 Mac 是否支援 Virtualization.framework。
	///
	/// Apple Silicon 一律 `true`；Intel 視機型而定。這是跟框架對話時最不需要
	/// 前置設定的一個問題——拿來驗證「框架連接成功」剛好。
	public static var supportsVirtualization: Bool {
		VZVirtualMachine.isSupported
	}

	/// 框架允許的 CPU 數範圍。建立 VM 設定時 `cpuCount` 必須落在此區間，
	/// 否則 `validate()` 會擋下。
	public static var allowedCPUCount: ClosedRange<Int> {
		VZVirtualMachineConfiguration.minimumAllowedCPUCount
			... VZVirtualMachineConfiguration.maximumAllowedCPUCount
	}

	/// 框架允許的記憶體大小範圍（bytes）。`memorySize` 必須落在此區間，
	/// 且為 1 MiB 的整數倍。
	public static var allowedMemoryBytes: ClosedRange<UInt64> {
		VZVirtualMachineConfiguration.minimumAllowedMemorySize
			... VZVirtualMachineConfiguration.maximumAllowedMemorySize
	}
}
