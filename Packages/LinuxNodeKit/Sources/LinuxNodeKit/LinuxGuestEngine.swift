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
	/// tag，只有逐版本 tag。
	public static let defaultInitfsReference: String = "ghcr.io/apple/containerization/vminit:0.37.0"

	/// - Parameters:
	///   - resolver: golden 別名 → OCI image 參照 ＋ kernel 的解析。
	///   - kernelProvisioner: kernel fetch-on-demand（快取命中直接回、否則抓＋驗＋落地）。
	///   - stateRoot: 容器 image store／rootfs 根目錄，預設 ``LinuxNodePaths/containerRoot(environment:)``。
	///   - initfsReference: vminitd guest agent 的 OCI 參照。
	///   - rootfsSizeInBytes: 容器 rootfs 上限，M1 沿用 PoC 驗證過的 1 GiB。
	public init(
		resolver: LinuxImageResolver = .init(),
		kernelProvisioner: LinuxKernelProvisioner = .init(),
		stateRoot: URL = LinuxNodePaths.containerRoot(),
		initfsReference: String = LinuxGuestEngine.defaultInitfsReference,
		rootfsSizeInBytes: UInt64 = 1.gib()
	) {
		self.resolver = resolver
		self.kernelProvisioner = kernelProvisioner
		self.stateRoot = stateRoot
		self.initfsReference = initfsReference
		self.rootfsSizeInBytes = rootfsSizeInBytes
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
			manager = try await ContainerManager(kernel: kernel, initfsReference: initfsReference, root: stateRoot)
		} catch {
			throw NymphError.internalFailure("linux container manager init failed: \(error)")
		}

		let container: LinuxContainer
		do {
			container = try await manager.create(
				containerID,
				reference: spec.imageReference,
				rootfsSizeInBytes: rootfsSizeInBytes,
				networking: false
			) { configuration in
				configuration.cpus = cpus
				configuration.memoryInBytes = memoryGiB.gib()
				configuration.process.arguments = LinuxGuestControl.keepAliveArguments
			}
		} catch {
			throw NymphError.cloneFailed("linux container create failed: \(error)")
		}

		let control: LinuxGuestControl = .init(
			manager: manager,
			container: container,
			containerID: containerID,
			readinessTimeout: readinessTimeout
		)
		let clonePath: URL = stateRoot.appending(component: "containers").appending(component: containerID)
		return ProvisionedGuest(control: control, goldenAlias: golden, clonePath: clonePath)
	}

	// MARK: Private

	private let resolver: LinuxImageResolver

	private let kernelProvisioner: LinuxKernelProvisioner

	private let stateRoot: URL

	private let initfsReference: String

	private let rootfsSizeInBytes: UInt64

	/// 容器 id：`mfly-linux-` 前綴 + UUID，避免與其他 Linux 節點或並行 provision 撞號。
	private static func makeContainerID() -> String {
		"mfly-linux-" + UUID().uuidString.lowercased()
	}
}

#endif
