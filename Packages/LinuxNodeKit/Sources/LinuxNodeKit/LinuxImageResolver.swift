//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit

/// golden 別名 → OCI image 參照 ＋ kernel 的解析。
///
/// **別名解析**（依序）：
/// 1. 別名本身**像一個 OCI 參照**（含 `/` 或 `:`）→ 原樣 passthrough（逃生梯，讓進階
///    用途直指任意 registry / repo / tag，同 ``GoldenResolver`` 對絕對路徑的 passthrough
///    精神）。
/// 2. 否則查操作者的別名表（``LinuxImageManifest``，沒有這份檔就跳過這一步）。
/// 3. 否則查內建別名表，查無擲 ``NymphError/goldenNotFound(_:)``。
///
/// 別名表排在內建表之前：內建表編在 binary 裡、換一顆映像要重出一版，操作者手上那份檔
/// 才是這台機器當下真正在用的答案，同名時以它為準。
///
/// kernel 選型 M1 為單一全域 pin（``LinuxKernelArchive/default``）——per-alias 客製化
/// kernel 留後續（現無此需求）。
public struct LinuxImageResolver: Sendable {

	// MARK: Public

	/// 內建別名表：alias → OCI image 參照。M1 只收 PoC 驗證過的 `alpine`。
	public static let defaultAliases: [String: String] = [
		"alpine": "docker.io/library/alpine:3",
	]

	/// 操作者維護的別名表；`nil`＝這台機器上沒有這份檔，只用內建表。
	public let manifest: LinuxImageManifest?

	/// 編在 binary 裡的別名表。
	public let builtInAliases: [String: String]

	/// 所有別名共用的 kernel。
	public let kernel: LinuxKernelArchive

	/// - Parameters:
	///   - manifest: 操作者維護的別名表；`nil`＝只用內建表。
	///   - builtInAliases: 編在 binary 裡的別名表。
	///   - kernel: 所有別名共用的 kernel。
	public init(
		manifest: LinuxImageManifest? = nil,
		builtInAliases: [String: String] = LinuxImageResolver.defaultAliases,
		kernel: LinuxKernelArchive = .default
	) {
		self.manifest = manifest
		self.builtInAliases = builtInAliases
		self.kernel = kernel
	}

	/// 解析別名成 ``LinuxGuestSpec``（規則見型別註解）。
	/// - Parameter alias: `spawn` 帶來的 golden 別名。
	/// - Returns: 要拉哪顆映像、配哪顆 kernel、rootfs 多大。
	/// - Throws: ``NymphError/goldenNotFound(_:)``——三條路都沒命中。
	public func resolve(_ alias: String) throws -> LinuxGuestSpec {
		if alias.contains("/") || alias.contains(":") {
			return LinuxGuestSpec(imageReference: alias, kernel: kernel)
		}
		if let entry: LinuxImageManifest.Entry = manifest?.images[alias] {
			return LinuxGuestSpec(
				imageReference: entry.reference,
				kernel: kernel,
				rootfsSizeInBytes: entry.rootfsSizeInBytes
			)
		}
		guard let reference: String = builtInAliases[alias] else { throw NymphError.goldenNotFound(alias) }
		return LinuxGuestSpec(imageReference: reference, kernel: kernel)
	}
}
