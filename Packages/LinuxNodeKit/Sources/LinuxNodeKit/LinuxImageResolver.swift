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
/// 2. 否則查內建別名表，查無擲 ``NymphError/goldenNotFound(_:)``。
///
/// kernel 選型 M1 為單一全域 pin（``LinuxKernelArchive/default``）——per-alias 客製化
/// kernel 留後續（現無此需求）。
public struct LinuxImageResolver: Sendable {

	// MARK: Public

	/// 內建別名表：alias → OCI image 參照。M1 只收 PoC 驗證過的 `alpine`。
	public static let defaultAliases: [String: String] = [
		"alpine": "docker.io/library/alpine:3",
	]

	public let aliases: [String: String]

	public let kernel: LinuxKernelArchive

	public init(aliases: [String: String] = LinuxImageResolver.defaultAliases, kernel: LinuxKernelArchive = .default) {
		self.aliases = aliases
		self.kernel = kernel
	}

	/// 解析別名成 ``LinuxGuestSpec``（規則見型別註解）。
	public func resolve(_ alias: String) throws -> LinuxGuestSpec {
		if alias.contains("/") || alias.contains(":") {
			return LinuxGuestSpec(imageReference: alias, kernel: kernel)
		}
		guard let reference = aliases[alias] else {
			throw NymphError.goldenNotFound(alias)
		}
		return LinuxGuestSpec(imageReference: reference, kernel: kernel)
	}
}