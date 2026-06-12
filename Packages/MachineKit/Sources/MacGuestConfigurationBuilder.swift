//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization

// Mac guest 的 VZ 型別（VZMacPlatformConfiguration 等）在 SDK header 整體被
// `#ifdef __arm64__` 包住——x86_64 編譯時符號不存在，須以 arch 條件編譯隔離；
// Intel host 上本檔不參與編譯、套件只剩 Host 與 MacGuestSpec。
#if arch(arm64)

// MARK: - MacGuestConfigurationError

/// 把 ``MacGuestSpec`` 翻成 VZ 設定時可能發生的錯誤。
///
/// 只涵蓋 spec 層的檢查；VZ 層的失敗（磁碟附掛、`validate()`）原樣擲框架的
/// `VZError`，留給呼叫端對 `VZErrorDomain` 處理。
public enum MacGuestConfigurationError: Error {

	/// 開機磁碟不存在。
	case diskImageMissing(URL)

	/// 身份持久化檔不存在（machineIdentifier / hardwareModel / auxiliaryStorage）。
	case identityFileMissing(URL)

	/// 身份持久化資料無法重建型別（檔案損毀、或非本框架存出的內容）。
	case identityDataInvalid(URL)

	/// 這台 host 跑不動該硬體模型（host 版本低於模型要求等）。
	case hardwareModelUnsupported

	/// MAC 位址字串格式不合法。
	case invalidMACAddress(String)
}

// MARK: - MacGuestConfigurationBuilder

/// 把 ``MacGuestSpec`` 翻成驗證過、可直接交給 `VZVirtualMachine` 的
/// `VZVirtualMachineConfiguration`。
///
/// 只負責**開機既有 guest**（load 路徑）：身份三件套（hardwareModel /
/// machineIdentifier / auxiliaryStorage）一律從磁碟還原、絕不新建。新建
/// （install 路徑、`creatingStorageAt:`）屬安裝器、由另一型別負責——兩路
/// 刻意分開，避免 clone / run 時誤建 aux storage 把烤進磁碟的身份洗掉
/// （結果是硬開機凍結、不是優雅地變一台新機）。
///
/// 裝置面向 headless SSH / serial 流程：只掛圖形、儲存、網路、entropy 與
/// 選配的 serial console，不含鍵盤 / 指向裝置——GUI 面落地時再補。
public enum MacGuestConfigurationBuilder {

	// MARK: Public

	/// guest serial console 的 host 端接線。
	///
	/// guest 把 readiness marker / IP 自報寫到 console、host 從 ``output`` 讀；
	/// 寫入 ``input`` 則送進 guest 輸入。這是取得 guest 狀態的主通道——完全
	/// 不經 host 網路，繞開 Local Network TCC。
	public struct Console {

		/// host → guest：寫進這個 handle 的資料送往 guest 輸入。
		public var input: FileHandle

		/// guest → host：guest 的 console 輸出寫到這個 handle。
		public var output: FileHandle

		public init(input: FileHandle, output: FileHandle) {
			self.input = input
			self.output = output
		}
	}

	/// 組出可開機的設定。回傳前已過 `validate()`。
	///
	/// `cpuCount` / `memoryBytes` 超出 ``Host`` 允許範圍時自動收斂、不擲錯；
	/// spec 層問題擲 ``MacGuestConfigurationError``、VZ 層問題原樣擲 `VZError`。
	public static func makeConfiguration(
		from spec: MacGuestSpec,
		console: Console? = nil
	) throws -> VZVirtualMachineConfiguration {
		let configuration: VZVirtualMachineConfiguration = .init()
		configuration.platform = try makePlatform(from: spec)
		configuration.bootLoader = VZMacOSBootLoader()
		configuration.cpuCount = Host.clampedCPUCount(spec.cpuCount)
		configuration.memorySize = Host.clampedMemoryBytes(spec.memoryBytes)
		// 空 graphicsDevices 會過 validate、能開機、但 guest 永遠進不了可連線
		// 狀態（見 MacGuestSpec.Display doc）——headless 是「不開視窗」、不是不掛。
		configuration.graphicsDevices = [makeGraphics(from: spec.display)]
		configuration.storageDevices = try [makeBootDisk(from: spec)]
		configuration.networkDevices = try [makeNetwork(macAddress: spec.macAddress)]
		configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		if let console {
			configuration.serialPorts = [makeSerialPort(console)]
		}
		try configuration.validate()
		return configuration
	}

	// MARK: Private

	/// 從持久化檔還原平台身份三件套。
	private static func makePlatform(from spec: MacGuestSpec) throws -> VZMacPlatformConfiguration {
		let platform: VZMacPlatformConfiguration = .init()
		let hardwareModelData = try identityData(at: spec.hardwareModel)
		guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
			throw MacGuestConfigurationError.identityDataInvalid(spec.hardwareModel)
		}
		guard hardwareModel.isSupported else {
			throw MacGuestConfigurationError.hardwareModelUnsupported
		}
		platform.hardwareModel = hardwareModel
		let identifierData = try identityData(at: spec.machineIdentifier)
		guard let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
			throw MacGuestConfigurationError.identityDataInvalid(spec.machineIdentifier)
		}
		platform.machineIdentifier = identifier
		guard FileManager.default.fileExists(atPath: spec.auxiliaryStorage.path) else {
			throw MacGuestConfigurationError.identityFileMissing(spec.auxiliaryStorage)
		}
		platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: spec.auxiliaryStorage)
		return platform
	}

	private static func identityData(at url: URL) throws -> Data {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw MacGuestConfigurationError.identityFileMissing(url)
		}
		return try Data(contentsOf: url)
	}

	private static func makeGraphics(from display: MacGuestSpec.Display) -> VZMacGraphicsDeviceConfiguration {
		let graphics: VZMacGraphicsDeviceConfiguration = .init()
		graphics.displays = [
			VZMacGraphicsDisplayConfiguration(
				widthInPixels: display.widthInPixels,
				heightInPixels: display.heightInPixels,
				pixelsPerInch: display.pixelsPerInch
			)
		]
		return graphics
	}

	private static func makeBootDisk(from spec: MacGuestSpec) throws -> VZVirtioBlockDeviceConfiguration {
		guard FileManager.default.fileExists(atPath: spec.diskImage.path) else {
			throw MacGuestConfigurationError.diskImageMissing(spec.diskImage)
		}
		let attachment = try VZDiskImageStorageDeviceAttachment(url: spec.diskImage, readOnly: false)
		return VZVirtioBlockDeviceConfiguration(attachment: attachment)
	}

	private static func makeNetwork(macAddress: String?) throws -> VZVirtioNetworkDeviceConfiguration {
		let network: VZVirtioNetworkDeviceConfiguration = .init()
		network.attachment = VZNATNetworkDeviceAttachment()
		if let macAddress {
			guard let resolved = VZMACAddress(string: macAddress) else {
				throw MacGuestConfigurationError.invalidMACAddress(macAddress)
			}
			network.macAddress = resolved
		}
		return network
	}

	private static func makeSerialPort(_ console: Console) -> VZVirtioConsoleDeviceSerialPortConfiguration {
		let port: VZVirtioConsoleDeviceSerialPortConfiguration = .init()
		// VZFileHandleSerialPortAttachment 語意：寫進 fileHandleForReading 的資料
		// 送往 guest、guest 輸出寫到 fileHandleForWriting。
		port.attachment = VZFileHandleSerialPortAttachment(
			fileHandleForReading: console.input,
			fileHandleForWriting: console.output
		)
		return port
	}
}

#endif
