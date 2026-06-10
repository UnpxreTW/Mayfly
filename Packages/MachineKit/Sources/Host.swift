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
		Config.minimumAllowedCPUCount ... Config.maximumAllowedCPUCount
	}

	/// 框架允許的記憶體大小範圍（bytes）。`memorySize` 必須落在此區間，
	/// 且為 1 MiB 的整數倍。
	public static var allowedMemoryBytes: ClosedRange<UInt64> {
		Config.minimumAllowedMemorySize ... Config.maximumAllowedMemorySize
	}

	/// 把要求的 CPU 數收進 ``allowedCPUCount`` 範圍。
	public static func clampedCPUCount(_ requested: Int) -> Int {
		min(max(requested, allowedCPUCount.lowerBound), allowedCPUCount.upperBound)
	}

	/// 把要求的記憶體收進 ``allowedMemoryBytes`` 範圍、並向下對齊 1 MiB 倍數
	/// （框架要求 `memorySize` 為 1 MiB 整數倍）。
	public static func clampedMemoryBytes(_ requested: UInt64) -> UInt64 {
		let oneMiB: UInt64 = 1 << 20
		// 下界先向上對齊，floor 後才不會跌破下界、或在下界本身未對齊時吐出
		// 非 1 MiB 倍數的值。
		let alignedMinimum = (allowedMemoryBytes.lowerBound + oneMiB - 1) / oneMiB * oneMiB
		let clamped = min(max(requested, alignedMinimum), allowedMemoryBytes.upperBound)
		return clamped / oneMiB * oneMiB
	}

	/// `VZVirtualMachineConfiguration` 的本地縮寫，純為可讀性。
	private typealias Config = VZVirtualMachineConfiguration
}
