//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization

// VZMacOSRestoreImage 系（含 mostFeaturefulSupportedConfiguration → VZMac*）只在
// arm64 SDK 有符號——整檔 arch gate；Intel 上 RestoreImageCache 仍可用。
#if arch(arm64)

/// macOS restore image 的取得：抓最新支援 metadata、下載到快取、load 本機檔、
/// 取出建立一台 guest 所需的硬體要求，與 VZ 生命週期解耦（不持有 VM）。
///
/// `VZMacOSRestoreImage` 的 fetch / load 都是 `@Sendable` 的 Result-completion
/// class method（header `NS_REFINED_FOR_SWIFT`；另有 async 糖、但這裡顯式包
/// continuation 以在 completion 內抽出 Sendable 純值、不把非 Sendable 的 image /
/// requirements 跨界外送）。fetch 回的 `.url` 是**網路** URL，~16.5GB .ipsw 須自行
/// 下載到快取再交給後續安裝層。
public struct RestoreImageProvider: Sendable {

	// MARK: Public

	/// 取得 restore image 過程的錯誤。
	public enum Error: Swift.Error {

		/// 這台 host 跑不動 image 的任何硬體模型（`mostFeaturefulSupportedConfiguration`
		/// 為 nil、或其 hardwareModel 不被 host 支援）。
		case noSupportedConfiguration

		/// 下載失敗（network / IO）。
		case downloadFailed(any Swift.Error)
	}

	/// 已備妥的 restore image：本機已下載的 .ipsw + 建一台 guest 所需的純值要求。
	///
	/// 刻意不外露 `VZMacOSRestoreImage` / `VZMacOSConfigurationRequirements`（皆非
	/// Sendable）：硬體模型以 `dataRepresentation`（`Data`）攜帶，安裝層用
	/// `VZMacHardwareModel(dataRepresentation:)` 重建、同一份同時餵 platform 與 aux
	/// 的 `creatingStorageAt:`（身份耦合要求 identical 值即可）。
	public struct Prepared: Sendable {

		/// 本機已下載並驗證存在的 .ipsw。
		public let localImageURL: URL

		/// image 的 OS build version（拿來命名快取、寫 metadata）。
		public let buildVersion: String

		/// image 的 OS 版本。
		public let osVersion: OperatingSystemVersion

		/// 本機 .ipsw 的 SHA256（稽核用、寫進 bundle metadata）。
		public let sha256: String

		/// 硬體模型的 `dataRepresentation`（安裝層重建用）。
		public let hardwareModelData: Data

		/// image 要求的最低 vCPU 數。
		public let minimumCPUCount: Int

		/// image 要求的最低記憶體（bytes）。
		public let minimumMemoryBytes: UInt64
	}

	/// 抓最新支援的 image：取 metadata → 快取命中則用、否則下載 → 取 SHA256 →
	/// 回傳 ``Prepared``。長跑網路操作（fetch + 可能的 ~16.5GB 下載）。
	public func prepareLatest() async throws -> Prepared {
		let metadata = try await fetchLatestMetadata()
		try ensureCacheDirectory()
		let localURL = cache.imageURL(buildVersion: metadata.buildVersion)
		if !cache.isCached(buildVersion: metadata.buildVersion) {
			try await download(from: metadata.remoteURL, to: localURL)
		}
		let sha256 = try cache.sha256(of: localURL)
		return metadata.prepared(localImageURL: localURL, sha256: sha256)
	}

	/// 接受外部已備妥的本機 .ipsw（跳過 fetch / download）：load 取要求、算 SHA256。
	public func prepare(localImageURL: URL) async throws -> Prepared {
		let metadata = try await loadMetadata(from: localImageURL)
		let sha256 = try cache.sha256(of: localImageURL)
		return metadata.prepared(localImageURL: localImageURL, sha256: sha256)
	}

	public init(cache: RestoreImageCache = .init()) {
		self.cache = cache
	}

	// MARK: Private

	/// 從 image 抽出的純值要求，與 ``Prepared`` 的差別只在尚未有本機檔 / SHA256。
	private struct Metadata {
		let remoteURL: URL
		let buildVersion: String
		let osVersion: OperatingSystemVersion
		let hardwareModelData: Data
		let minimumCPUCount: Int
		let minimumMemoryBytes: UInt64

		func prepared(localImageURL: URL, sha256: String) -> Prepared {
			Prepared(
				localImageURL: localImageURL,
				buildVersion: buildVersion,
				osVersion: osVersion,
				sha256: sha256,
				hardwareModelData: hardwareModelData,
				minimumCPUCount: minimumCPUCount,
				minimumMemoryBytes: minimumMemoryBytes
			)
		}
	}

	/// 在 completion 內把非 Sendable 的 image 抽成 Sendable 純值；host 跑不動則回
	/// failure。隔離邊界：image 不離開此函式。
	private static func metadata(from image: VZMacOSRestoreImage) -> Result<Metadata, any Swift.Error> {
		// mostFeaturefulSupportedConfiguration 非 nil 依 SDK 契約即「host 支援的最強
		// 配置」、其 hardwareModel 已是 supported——isSupported 再驗是 belt-and-
		// suspenders 防衛、契約上恆為 true，與 builder LOAD 路徑從磁碟資料重建
		// model 時的 isSupported（那裡才真的可能 false）語境不同。
		guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
			return .failure(Error.noSupportedConfiguration)
		}
		return .success(Metadata(
			remoteURL: image.url,
			buildVersion: image.buildVersion,
			osVersion: image.operatingSystemVersion,
			hardwareModelData: requirements.hardwareModel.dataRepresentation,
			minimumCPUCount: requirements.minimumSupportedCPUCount,
			minimumMemoryBytes: requirements.minimumSupportedMemorySize
		))
	}

	/// .ipsw 本機快取（命名 / 命中 / SHA256）。
	private let cache: RestoreImageCache

	/// fetch / load 倚賴 VZ 的「completion 恰呼叫一次」慣例（header 未明文保證、僅說
	/// 在任意 thread 回呼）；用 Checked（非 Unsafe）continuation 把任何違約轉成
	/// 確定性 trap、而非靜默吞值。
	private func fetchLatestMetadata() async throws -> Metadata {
		try await withCheckedThrowingContinuation { continuation in
			VZMacOSRestoreImage.fetchLatestSupported { result in
				continuation.resume(with: result.flatMap(Self.metadata(from:)))
			}
		}
	}

	private func loadMetadata(from fileURL: URL) async throws -> Metadata {
		try await withCheckedThrowingContinuation { continuation in
			VZMacOSRestoreImage.load(from: fileURL) { result in
				continuation.resume(with: result.flatMap(Self.metadata(from:)))
			}
		}
	}

	private func ensureCacheDirectory() throws {
		try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
	}

	/// 下載 .ipsw 到最終名。完整性保證：先把 URLSession 暫存檔搬進 cache 卷的
	/// `.partial`（跨卷時這步退化成 copy、但落點是 .partial、崩潰不污染最終名），
	/// 再**同卷 atomic rename** 成最終名——最終名只會經同卷 rename 出現，
	/// ``RestoreImageCache/isCached(buildVersion:)`` 不會撞到半成品。defer 確保
	/// 任何失敗路徑都不殘留暫存 / .partial（~16.5GB、洩漏代價高）。Task 取消透傳
	/// `CancellationError`、不誤報成 ``Error/downloadFailed(_:)``。
	private func download(from remoteURL: URL, to localURL: URL) async throws {
		let tempURL: URL
		do {
			(tempURL, _) = try await URLSession.shared.download(from: remoteURL)
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as URLError where error.code == .cancelled {
			throw CancellationError()
		} catch {
			throw Error.downloadFailed(error)
		}
		let manager: FileManager = .default
		let staging = cache.directory.appending(component: ".\(localURL.lastPathComponent).partial")
		try? manager.removeItem(at: staging)
		defer { try? manager.removeItem(at: tempURL) }
		defer { try? manager.removeItem(at: staging) }
		do {
			try manager.moveItem(at: tempURL, to: staging)
			try manager.moveItem(at: staging, to: localURL)
		} catch {
			throw Error.downloadFailed(error)
		}
	}
}

#endif
