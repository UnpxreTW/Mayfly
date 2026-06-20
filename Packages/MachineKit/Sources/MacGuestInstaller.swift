//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization

// 整檔碰 VZMac*（platform / aux / installer / hardwareModel）——arch gate；Intel
// 上套件只剩 Host / MacGuestSpec / KeychainPreflight / 準備層 / cache。
#if arch(arm64)

/// macOS guest 的 **CREATE 路徑**：從已備妥的 restore image 灌一台全新 macOS，
/// 新建並原子持久化身份五件套，產出「裝好但停在 Setup Assistant、未開機」的
/// `.bundle`，回傳可無轉換餵 ``MacGuestConfigurationBuilder`` LOAD 路徑的 spec。
///
/// 與 builder（LOAD、`init(url:)` 還原身份）**刻意分成不同型別**：CREATE 走
/// `creatingStorageAt:` 新建身份；run / clone 路徑誤呼 `creatingStorageAt:` 會洗掉
/// 烤進磁碟的身份 → 硬開機凍結。型別層硬分流比「靠檔案存在與否 runtime 分流」
/// 安全。
///
/// `@unchecked Sendable` 不變式同 ``MacGuest``：`virtualMachine` / `installer` / `observation`
/// 與兩個取消旗標（`installStarted` / `cancelledBeforeStart`）的「驅動 / 變更狀態」
/// 都只在私有 `vmQueue` 上（VZ 的 queue 合約含 init、callback、install）。出生與
/// KVO 註冊都包在 init 的 `queue.sync` 內；唯一在 vmQueue 外的觸碰是 `progress`
/// 的讀取（`NSProgress` 自身 thread-safe）。install 是 completionHandler + KVO
/// 地基、async 只是門面；**安裝期間絕不 start()**（installer 內部驅動 VM）。
/// 一台 installer 是**一次性**：install 完成 / 失敗即 teardown（drop VZ ref、
/// finish 進度流）、不重用。
public final class MacGuestInstaller: @unchecked Sendable {

	// MARK: Public

	public typealias Display = MacGuestSpec.Display

	/// 安裝進度流（`fractionCompleted`、0...1）。單一 consumer 語意；yield 自 KVO。
	/// install 期間 15-25 分長跑，靠這條觀察進度；成功時補 yield 1.0、收束時 finish。
	public let progress: AsyncStream<Double>

	/// 執行安裝。在 vmQueue 上 `install()`（completionHandler 包 continuation）；
	/// 成功後寫身份檔（hardwareModel / machineIdentifier 的 `dataRepresentation`）與
	/// `metadata.json`，回傳可直接餵 builder LOAD 路徑的 spec。無論成功 / 失敗 /
	/// 取消都 `defer teardown`（drop VZ ref 讓磁碟 file handle 釋放、finish 進度流）。
	/// Task 取消 → 起跑後 cancel progress、起跑前直接收束，皆擲
	/// ``MacGuestInstallerError/cancelled``。安裝期間不 start()。
	public func install() async throws -> MacGuestSpec {
		defer { teardown() }
		do {
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
					vmQueue.async {
						guard let installer = self.installer else {
							// teardown 已收束（一次性 installer 被重用）——與取消區分。
							continuation.resume(throwing: MacGuestInstallerError.alreadyConsumed)
							return
						}
						guard !self.cancelledBeforeStart else {
							// 取消早於起跑：絕不碰 progress（未起跑 cancel 會 raise
							// NSException、Swift 接不到），直接收束。
							continuation.resume(throwing: MacGuestInstallerError.cancelled)
							return
						}
						self.installStarted = true
						installer.install { continuation.resume(with: $0) }
					}
				}
			} onCancel: {
				// 與 operation 閉包同在 serial vmQueue 上序列化：起跑後才 cancel
				// progress，未起跑只立旗標、讓 operation 閉包以 .cancelled 收束。
				vmQueue.async {
					if self.installStarted {
						self.installer?.progress.cancel()
					} else {
						self.cancelledBeforeStart = true
					}
				}
			}
		} catch {
			// VZ 把取消回報為 VZError(.operationCancelled)（非 CancellationError）；
			// Task.isCancelled 也涵蓋「取消早於起跑」直接擲的 .cancelled。
			if Task.isCancelled || (error as? VZError)?.code == .operationCancelled {
				throw MacGuestInstallerError.cancelled
			}
			throw error
		}
		try persistIdentity()
		// KVO 多半已 yield 過終值；補一發確保 consumer 在 finish 前見得到 1.0。
		progressContinuation.yield(1.0)
		return GuestBundleLayout.spec(
			for: bundle,
			metadata: bundleMetadata,
			cpuCount: clampedCPUCount,
			memoryBytes: clampedMemoryBytes,
			display: display
		)
	}

	/// 在私有 vmQueue 上備妥 installer（尚未 install）：建 bundle 目錄、空 sparse
	/// 磁碟、新建身份三件套（`creatingStorageAt:`）、組驗證過的 install config、建
	/// VM 與 `VZMacOSInstaller`。資源 clamp 同時尊重 image 最低要求與 ``Host`` 允許
	/// 範圍；image 最低反被 host 上限夾到更低時擲
	/// ``MacGuestInstallerError/resourceRequirementsExceedHost``（不以 under-spec
	/// 設定 install）。bundle 已存在且未 `overwrite` 擲
	/// ``MacGuestInstallerError/bundleAlreadyExists(_:)``。
	public init(
		bundle: URL,
		prepared: RestoreImageProvider.Prepared,
		cpuCount: Int = 4,
		memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024,
		display: Display = .init(),
		macAddress: String? = nil,
		diskNominalBytes: UInt64 = BootDiskImage.defaultNominalBytes,
		overwrite: Bool = false
	) throws {
		let manager: FileManager = .default
		if manager.fileExists(atPath: bundle.path) {
			guard overwrite else {
				throw MacGuestInstallerError.bundleAlreadyExists(bundle)
			}
		}
		// 顯式型別必填：static method 回傳型別 ≠ 外層型別，省略會被 formatter 的
		// propertyTypes 規則誤改成 `: Host` 致編譯不過。
		let cpu: Int = Host.clampedCPUCount(max(cpuCount, prepared.minimumCPUCount))
		let memory: UInt64 = Host.clampedMemoryBytes(max(memoryBytes, prepared.minimumMemoryBytes))
		// host 上限把資源夾到 image 最低以下＝這台 host 跑不動該 image；低於最低
		// 是 undefined behavior，先擋掉（在任何檔案副作用前 fail fast）。
		guard cpu >= prepared.minimumCPUCount, memory >= prepared.minimumMemoryBytes else {
			throw MacGuestInstallerError.resourceRequirementsExceedHost
		}
		let resolvedMAC = macAddress ?? VZMACAddress.randomLocallyAdministered().string
		try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
		let diskURL: URL = GuestBundleLayout.diskImage(in: bundle)
		try BootDiskImage.create(at: diskURL, nominalBytes: diskNominalBytes, overwrite: overwrite)
		let (stream, continuation) = AsyncStream.makeStream(of: Double.self)
		let queue: DispatchQueue = .init(label: "MachineKit.MacGuestInstaller")
		// 身份建立、VM / installer 出生、KVO 註冊都在 vmQueue 上（VZ 的 queue 合約
		// 含 init）。
		let built = try queue.sync {
			try Self.buildVM(
				BuildRequest(
					prepared: prepared,
					auxURL: GuestBundleLayout.auxiliaryStorage(in: bundle),
					diskURL: diskURL,
					cpuCount: cpu,
					memoryBytes: memory,
					display: display,
					overwrite: overwrite
				),
				queue: queue,
				continuation: continuation
			)
		}
		self.vmQueue = queue
		self.virtualMachine = built.machine
		self.installer = built.installer
		self.observation = built.observation
		self.progress = stream
		self.progressContinuation = continuation
		self.bundle = bundle
		self.hardwareModelData = prepared.hardwareModelData
		self.machineIdentifierData = built.machineIdentifierData
		self.macAddress = resolvedMAC
		self.buildVersion = prepared.buildVersion
		self.osVersion = prepared.osVersion
		self.sha256 = prepared.sha256
		self.clampedCPUCount = cpu
		self.clampedMemoryBytes = memory
		self.display = display
	}

	// MARK: Private

	/// `buildVM` 的輸入（收進 struct 以收斂參數數）。
	private struct BuildRequest {

		let prepared: RestoreImageProvider.Prepared

		let auxURL: URL

		let diskURL: URL

		let cpuCount: Int

		let memoryBytes: UInt64

		let display: Display

		let overwrite: Bool
	}

	/// `buildVM` 在 vmQueue 上產出的一組物件（替代多元 tuple）。
	private struct Built {

		let machine: VZVirtualMachine

		let installer: VZMacOSInstaller

		let machineIdentifierData: Data

		let observation: NSKeyValueObservation
	}

	/// 在 vmQueue 上新建身份三件套（`creatingStorageAt:`）、組驗證過的 install
	/// config、建 VM 與 `VZMacOSInstaller`、註冊進度 KVO。hardwareModel 重建一次、
	/// 同份同時餵 platform 與 aux（身份耦合要求 identical 值）。host 跑不動該硬體
	/// 模型擲 ``MacGuestInstallerError/hardwareModelUnsupported``。
	private static func buildVM(
		_ request: BuildRequest,
		queue: DispatchQueue,
		continuation: AsyncStream<Double>.Continuation
	) throws -> Built {
		guard
			let hardwareModel = VZMacHardwareModel(dataRepresentation: request.prepared.hardwareModelData),
			hardwareModel.isSupported
		else {
			throw MacGuestInstallerError.hardwareModelUnsupported
		}
		let machineIdentifier: VZMacMachineIdentifier = .init()
		let platform: VZMacPlatformConfiguration = .init()
		platform.hardwareModel = hardwareModel
		platform.machineIdentifier = machineIdentifier
		platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
			creatingStorageAt: request.auxURL,
			hardwareModel: hardwareModel,
			options: request.overwrite ? [.allowOverwrite] : []
		)
		let configuration: VZVirtualMachineConfiguration = try installConfiguration(
			platform: platform,
			diskURL: request.diskURL,
			cpuCount: request.cpuCount,
			memoryBytes: request.memoryBytes,
			display: request.display
		)
		try configuration.validate()
		let machine: VZVirtualMachine = .init(configuration: configuration, queue: queue)
		let installer: VZMacOSInstaller = .init(virtualMachine: machine, restoringFromImageAt: request.prepared.localImageURL)
		// closure 只捕 Sendable continuation、不捕 self；.initial 在此（vmQueue）
		// 同步 fire 一次 yield 0.0。
		let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
			continuation.yield(progress.fractionCompleted)
		}
		return Built(
			machine: machine,
			installer: installer,
			machineIdentifierData: machineIdentifier.dataRepresentation,
			observation: observation
		)
	}

	/// 組 install config：身份 platform + macOS bootloader + clamp 過的 cpu/mem +
	/// raw 開機磁碟 + 圖形（macOS guest 即使 headless 也須掛、否則開得起卻連不上）。
	/// install 不需網路、不掛。disk attachment 失敗原樣上拋（帶 `VZError` 確切成因、
	/// 不吞成 validate 的通用錯誤）。
	private static func installConfiguration(
		platform: VZMacPlatformConfiguration,
		diskURL: URL,
		cpuCount: Int,
		memoryBytes: UInt64,
		display: Display
	) throws -> VZVirtualMachineConfiguration {
		let configuration: VZVirtualMachineConfiguration = .init()
		configuration.platform = platform
		configuration.bootLoader = VZMacOSBootLoader()
		configuration.cpuCount = cpuCount
		configuration.memorySize = memoryBytes
		let attachment: VZDiskImageStorageDeviceAttachment = try .init(url: diskURL, readOnly: false)
		configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
		let graphics: VZMacGraphicsDeviceConfiguration = .init()
		graphics.displays = [
			VZMacGraphicsDisplayConfiguration(
				widthInPixels: display.widthInPixels,
				heightInPixels: display.heightInPixels,
				pixelsPerInch: display.pixelsPerInch
			)
		]
		configuration.graphicsDevices = [graphics]
		return configuration
	}

	/// 寫進 bundle 的建立資訊。
	private var bundleMetadata: BundleMetadata {
		BundleMetadata(
			macAddress: macAddress,
			osBuildVersion: buildVersion,
			osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
			restoreImageSHA256: sha256
		)
	}

	/// 一切 VZ 觸碰的唯一入口。
	private let vmQueue: DispatchQueue

	/// 被驅動的 VM；teardown 後 nil。只在 vmQueue 上觸碰。
	private var virtualMachine: VZVirtualMachine?

	/// 安裝器；teardown 後 nil。只在 vmQueue 上觸碰。
	private var installer: VZMacOSInstaller?

	/// 進度 KVO observation；teardown 時 invalidate。只在 vmQueue 上觸碰。
	private var observation: NSKeyValueObservation?

	/// install 是否已起跑——gate `progress.cancel()`（未起跑 cancel 會 raise）。
	/// 只在 vmQueue 上觸碰。
	private var installStarted = false

	/// 取消是否早於 install 起跑——讓 operation 閉包以 .cancelled 收束。只在
	/// vmQueue 上觸碰。
	private var cancelledBeforeStart = false

	/// 進度流出口（Sendable）。
	private let progressContinuation: AsyncStream<Double>.Continuation

	/// 身份原子 bundle 的目錄。
	private let bundle: URL

	/// 硬體模型的 `dataRepresentation`（install 後寫 `hardwareModel.bin`）。
	private let hardwareModelData: Data

	/// 機器識別碼的 `dataRepresentation`（install 後寫 `machineIdentifier.bin`）。
	private let machineIdentifierData: Data

	/// 固定 MAC（寫進 metadata、LOAD 路徑套用）。
	private let macAddress: String

	/// 安裝來源的 OS build version。
	private let buildVersion: String

	/// 安裝來源的 OS 版本。
	private let osVersion: OperatingSystemVersion

	/// 安裝所用 .ipsw 的 SHA256。
	private let sha256: String

	/// clamp 後的 vCPU 數（回傳 spec 用）。
	private let clampedCPUCount: Int

	/// clamp 後的記憶體（回傳 spec 用）。
	private let clampedMemoryBytes: UInt64

	/// 顯示器設定（回傳 spec 用）。
	private let display: Display

	/// install 成功後把身份原子的 .bin 與 metadata.json 落盤（aux / disk 已在 init
	/// 產出）。任一寫失敗擲 ``MacGuestInstallerError/identityWriteFailed(_:underlying:)``。
	private func persistIdentity() throws {
		try write(hardwareModelData, to: GuestBundleLayout.hardwareModel(in: bundle))
		try write(machineIdentifierData, to: GuestBundleLayout.machineIdentifier(in: bundle))
		let metadataURL: URL = GuestBundleLayout.metadata(in: bundle)
		do {
			let encoder: JSONEncoder = .init()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			try encoder.encode(bundleMetadata).write(to: metadataURL, options: .atomic)
		} catch {
			throw MacGuestInstallerError.identityWriteFailed(metadataURL, underlying: error)
		}
	}

	private func write(_ data: Data, to url: URL) throws {
		do {
			try data.write(to: url, options: .atomic)
		} catch {
			throw MacGuestInstallerError.identityWriteFailed(url, underlying: error)
		}
	}

	/// drop VZ ref（讓磁碟 file handle 釋放）、停 KVO、finish 進度流。冪等——每次
	/// install() 結束由 `defer` 無條件呼叫一次。`vmQueue.sync` 在 install 收束後
	/// （queue 已閒）短暫阻塞呼叫端，換得回傳 spec 前 VZ ref 確實釋放。
	private func teardown() {
		vmQueue.sync {
			observation?.invalidate()
			observation = nil
			installer = nil
			virtualMachine = nil
		}
		progressContinuation.finish()
	}
}

#endif
