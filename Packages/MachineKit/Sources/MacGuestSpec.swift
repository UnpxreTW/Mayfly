//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 描述我們想開的一台 macOS guest。
///
/// 只 import Foundation、不碰 Virtualization——CLI / GUI / MCP 都能組一份，把它
/// 翻成 VZ 設定是引擎內層的事。欄位刻意只放「持久狀態的檔案位置」加少數執行
/// 參數，不放任何 VZ 型別。
public struct MacGuestSpec: Sendable {

	/// macOS guest 的顯示器設定。
	///
	/// macOS 一定要掛圖形裝置（即使 headless、沒開視窗也要），否則開得起來卻
	/// 無法正常進系統 / 被連線——這是 macOS guest 與 Linux 最大的差異之一。
	public struct Display: Sendable {

		public var widthInPixels: Int

		public var heightInPixels: Int

		public var pixelsPerInch: Int

		public init(
			widthInPixels: Int = 1920,
			heightInPixels: Int = 1080,
			pixelsPerInch: Int = 80
		) {
			self.widthInPixels = widthInPixels
			self.heightInPixels = heightInPixels
			self.pixelsPerInch = pixelsPerInch
		}
	}

	/// 主磁碟映像（RAW）。macOS 已安裝在這顆磁碟上。
	public var diskImage: URL

	/// 輔助儲存（auxiliary storage）的檔案位置。存放 macOS guest 的機器狀態，
	/// 類比 Linux 的 nvram，但 macOS 專屬、由框架建立與管理。
	public var auxiliaryStorage: URL

	/// 機器識別碼（machine identifier）的持久化檔案。每台 VM 一個固定身分，跨
	/// 重開機必須一致，否則 guest 會認為硬體被換掉。
	public var machineIdentifier: URL

	/// 硬體模型（hardware model）的持久化檔案。安裝時從 `.ipsw` restore image
	/// 取得；之後每次開機都要用它重建平台設定。
	public var hardwareModel: URL

	public var cpuCount: Int

	public var memoryBytes: UInt64

	public var display: Display

	public init(
		diskImage: URL,
		auxiliaryStorage: URL,
		machineIdentifier: URL,
		hardwareModel: URL,
		cpuCount: Int = 4,
		memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024,
		display: Display = Display()
	) {
		self.diskImage = diskImage
		self.auxiliaryStorage = auxiliaryStorage
		self.machineIdentifier = machineIdentifier
		self.hardwareModel = hardwareModel
		self.cpuCount = cpuCount
		self.memoryBytes = memoryBytes
		self.display = display
	}
}
