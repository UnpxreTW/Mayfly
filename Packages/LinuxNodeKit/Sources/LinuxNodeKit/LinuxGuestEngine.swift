//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationOS
import Foundation
import NymphKit

// LinuxGuestEngine 觸碰 Containerization 的真容器 API——整檔 arch gate，比照
// RealGuestEngine.swift（NymphKit/RealGuestEngine.swift）：核心邏輯（LinuxImageResolver／
// LinuxKernelCache／LinuxKernelProvisioner／LinuxGuestErrorMapping）arch-neutral、可跨
// arch 以 fake 測；只有這層與 ``LinuxGuestControl`` 真接引擎。非 arm64 由 `mayfly nymph`
// 命令層擋下（比照 RealGuestEngine 的既有慣例）。

#if arch(arm64)

/// ``GuestEngine`` 的 Linux 實作：golden 別名 → OCI image 參照 ＋ kernel
/// （``LinuxImageResolver``）→ kernel fetch-on-demand（``LinuxKernelProvisioner``）→
/// `ContainerManager.create` 把 rootfs 解包備妥（未 start）→ 包成 ``LinuxGuestControl``。
/// 與 ``RealGuestEngine`` 對稱：本層只做別名解析、kernel 落地、容器物件建立的接線，
/// 不改 Containerization 本身。
public struct LinuxGuestEngine: GuestEngine {

	// MARK: Public

	/// vminitd 版本需與 containerization 套件版本對齊——GHCR 上該 image 無 `latest`
	/// tag，只有逐版本 tag。版本正本＝``LinuxToolchain/containerizationVersion``
	/// （對齊機制與升版程序見該處）。
	public static let defaultInitfsReference: String =
		"ghcr.io/apple/containerization/vminit:\(LinuxToolchain.containerizationVersion)"

	/// - Parameters:
	///   - resolver: golden 別名 → OCI image 參照 ＋ kernel 的解析。
	///   - kernelProvisioner: kernel fetch-on-demand（快取命中直接回、否則抓＋驗＋落地）。
	///   - stateRoot: 容器 image store／rootfs 根目錄，預設 ``LinuxNodePaths/containerRoot(environment:)``。
	///   - initfsReference: vminitd guest agent 的 OCI 參照。
	///   - rootfsSizeInBytes: 容器 rootfs 上限，M1 沿用 PoC 驗證過的 1 GiB。
	///   - network: 容器網路。`nil`（預設）＝不接網路，容器沒有對外連線、也不會有 IP；
	///     要接網路時傳一顆**整個引擎壽命共用**的 ``LinuxContainerNetwork``
	///     （見 ``LinuxContainerNetwork/vmnet(mtu:)``，該型別文件說明為何必須共用同一顆）。
	public init(
		resolver: LinuxImageResolver = .init(),
		kernelProvisioner: LinuxKernelProvisioner = .init(),
		stateRoot: URL = LinuxNodePaths.containerRoot(),
		initfsReference: String = LinuxGuestEngine.defaultInitfsReference,
		rootfsSizeInBytes: UInt64 = 1.gib(),
		network: LinuxContainerNetwork? = nil
	) {
		self.resolver = resolver
		self.kernelProvisioner = kernelProvisioner
		self.stateRoot = stateRoot
		self.initfsReference = initfsReference
		self.rootfsSizeInBytes = rootfsSizeInBytes
		self.network = network
	}

	public func provision(
		golden: String,
		cpus: Int,
		memoryGiB: Int,
		readinessTimeout: Duration
	) async throws -> ProvisionedGuest {
		guard memoryGiB > 0, UInt64(memoryGiB) <= UInt64.max >> 30 else {
			throw NymphError.internalFailure("memory_gib out of range: \(memoryGiB)")
		}
		let spec: LinuxGuestSpec = try resolver.resolve(golden)
		let kernelPath: URL = try await kernelProvisioner.prepare(spec.kernel)
		let kernel: Kernel = .init(path: kernelPath, platform: .linuxArm)
		let containerID: String = LinuxGuestEngine.makeContainerID()

		var manager: ContainerManager
		do {
			manager = try await ContainerManager(
				kernel: kernel,
				initfsReference: initfsReference,
				root: stateRoot,
				network: network
			)
		} catch {
			throw NymphError.internalFailure("linux container manager init failed: \(error)")
		}

		// `networking:` 一律由網路是否在場推導、不寫死常數。上游 `ContainerManager.create`
		// 那段是 `if networking { if let interface = try self.network?.createInterface(id) { … } }`
		// ——`networking: true` 配上 `network == nil` 時整段被 optional-chain 靜默跳過，不設介面、
		// 不設 DNS、不拋錯、不警告，結果是「編得過、跑得起來、容器就是沒網路」。由 network 推導
		// 讓兩者結構上不可能不一致。
		let container: LinuxContainer
		do {
			container = try await manager.create(
				containerID,
				reference: spec.imageReference,
				rootfsSizeInBytes: rootfsSizeInBytes,
				networking: network != nil
			) { configuration in
				configuration.cpus = cpus
				configuration.memoryInBytes = memoryGiB.gib()
				configuration.process.arguments = LinuxGuestControl.keepAliveArguments
			}
		} catch {
			// create 是在內部先配介面、之後才可能擲錯的：失敗路徑不交還的話，位址會一直
			// 掛在共用配發表上直到行程結束。從未配發時交還是 no-op，故無條件補這一次。
			try? network?.releaseInterface(containerID)
			throw NymphError.cloneFailed("linux container create failed: \(error)")
		}

		let control: LinuxGuestControl = .init(
			manager: manager,
			container: container,
			containerID: containerID,
			readinessTimeout: readinessTimeout,
			network: network
		)
		// 對齊 containerization 0.37.0 `ContainerManager` 的實際佈局（已對上游原始碼驗證）：
		// per-container 狀態（rootfs.ext4／bootlog.log）落在 `<root>/containers/<id>`。
		let clonePath: URL = stateRoot.appending(component: "containers").appending(component: containerID)
		return ProvisionedGuest(control: control, goldenAlias: golden, clonePath: clonePath)
	}

	// MARK: Private

	private let resolver: LinuxImageResolver

	private let kernelProvisioner: LinuxKernelProvisioner

	private let stateRoot: URL

	private let initfsReference: String

	private let rootfsSizeInBytes: UInt64

	private let network: LinuxContainerNetwork?

	/// 容器 id：`mfly-linux-` 前綴 + UUID，避免與其他 Linux 節點或並行 provision 撞號。
	private static func makeContainerID() -> String {
		"mfly-linux-" + UUID().uuidString.lowercased()
	}
}

#endif
