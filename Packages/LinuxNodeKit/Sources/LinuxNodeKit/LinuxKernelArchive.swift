//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// kata-containers 預建 Linux kernel release 的下載規格：來源 URL、版本、封存檔 sha256
/// pin，與封存內 kernel 二進位的相對路徑。純值型別、與 arch 無關（下載／校驗／解壓不碰
/// Virtualization / Containerization）。
///
/// **授權面**：kernel 二進位為 GPL-2.0，**執行期 fetch、永不隨 Mayfly 發佈物 / repo 打包**
/// ——散布義務留在上游 kata-containers release，Mayfly 自身維持純 Apache-2.0（單純聚合、
/// 不 link 進 host 行程，只在 guest VM 內當 OS 跑）。
public struct LinuxKernelArchive: Sendable, Equatable {

	/// kata-containers release 版本號（快取子目錄命名）。
	public let version: String

	/// 封存檔（`.tar.xz`）下載來源。
	public let archiveURL: URL

	/// 封存檔的 sha256（小寫 hex）——下載後驗證，不符即擲清楚錯誤。
	public let archiveSHA256: String

	/// 封存解壓（`--strip-components=1`）後，kernel 二進位的相對路徑。
	public let innerPath: String

	public init(version: String, archiveURL: URL, archiveSHA256: String, innerPath: String) {
		self.version = version
		self.archiveURL = archiveURL
		self.archiveSHA256 = archiveSHA256
		self.innerPath = innerPath
	}

	/// M1 落地預設：kata-containers 3.17.0 arm64——PoC 實測跑通的組合（containerization
	/// 0.37.0、alpine:3 rootfs），sha256 為當時下載實測值。
	public static let `default`: LinuxKernelArchive = .init(
		version: "3.17.0",
		archiveURL: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz")!,
		archiveSHA256: "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181",
		innerPath: "opt/kata/share/kata-containers/vmlinux.container"
	)
}