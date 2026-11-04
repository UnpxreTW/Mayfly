//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 燒一顆 Linux 映像之前就能決定、也就能先驗的部分：新別名、參照、rootfs 大小，以及在容器裡
/// 要跑的那幾條固定命令。
///
/// 實際燒製（起容器、跑設定、匯出、載入、冒煙）在 ``LinuxImageBaker``，那一層要真的開容器；
/// 這裡的檢查都排在開容器之前——設定腳本可能跑上幾十分鐘，別名打錯不該等到最後一步才知道。
public struct LinuxImageBakePlan: Sendable, Equatable {

	// MARK: Public

	/// 開工前就擋下的情況。
	public enum PlanError: Error, Equatable {

		/// 別名不符別名表的字元規則（見 ``LinuxImageManifest``），或轉成小寫後組不出合法的映像名
		/// （例如以 `-` 結尾）。
		case invalidAlias(String)

		/// 別名表已有這個別名、而呼叫端沒有要求覆寫。
		case aliasExists(String)

		/// 別名表已有一個只差大小寫的別名。兩者的本機參照都轉成小寫，會落在同一個名字上。
		case aliasCaseClash(alias: String, existing: String)

		/// rootfs 大小不是正整數、或大到換算成 bytes 會溢位。
		case invalidRootfsSize(Int)
	}

	/// 新映像在 image store 裡的參照（`mayfly.local/<小寫別名>:<標籤>`）。
	public let reference: String

	/// 要寫進別名表的別名。
	public let alias: String

	/// 起設定容器用的 base（別名或完整參照）。
	public let base: String

	/// 設定容器、冒煙容器與別名表條目共用的 rootfs 大小（GiB）；`nil`＝用引擎預設。
	public let rootfsGiB: Int?

	/// 別名已存在時是否覆寫。
	public let replacing: Bool

	/// - Parameters:
	///   - alias: 要寫進別名表的別名。
	///   - base: 起設定容器用的 base（別名或完整參照）。
	///   - rootfsGiB: 呼叫端指定的 rootfs 大小；`nil`＝沿用 base 別名在別名表裡的大小。
	///   - baseRootfsSizeInBytes: base 解析出的 rootfs 大小（bytes）；`nil`＝base 沒指定。
	///   - manifest: 目前的別名表；`nil`＝還沒有這份檔。
	///   - replacing: 別名已存在時是否覆寫。
	///   - created: 燒製時刻，決定標籤。
	/// - Throws: ``PlanError``。
	public init(
		alias: String,
		base: String,
		rootfsGiB: Int?,
		baseRootfsSizeInBytes: UInt64?,
		manifest: LinuxImageManifest?,
		replacing: Bool,
		created: Date
	) throws {
		guard LinuxImageManifest.isValidAlias(alias) else { throw PlanError.invalidAlias(alias) }
		if let manifest {
			if manifest.images[alias] != nil, !replacing {
				throw PlanError.aliasExists(alias)
			}
			let lowered: String = alias.lowercased()
			if let existing: String = manifest.images.keys.sorted().first(where: { $0 != alias && $0.lowercased() == lowered }) {
				throw PlanError.aliasCaseClash(alias: alias, existing: existing)
			}
		}
		if let rootfsGiB {
			guard
				rootfsGiB > 0,
				UInt64(rootfsGiB) <= UInt64.max >> 30
			else { throw PlanError.invalidRootfsSize(rootfsGiB) }
		}
		let tag: String = LinuxImageBakePlan.tag(for: created)
		let reference: String
		do {
			reference = try SingleLayerImageLayout.reference(alias: alias, tag: tag)
		} catch {
			throw PlanError.invalidAlias(alias)
		}
		self.reference = reference
		self.alias = alias
		self.base = base
		self.rootfsGiB = rootfsGiB ?? LinuxImageBakePlan.wholeGiB(baseRootfsSizeInBytes)
		self.replacing = replacing
	}

	/// ``rootfsGiB`` 換算成 bytes；`nil`＝用引擎預設。
	public var rootfsSizeInBytes: UInt64? {
		guard let rootfsGiB: Int = rootfsGiB else { return nil }
		return UInt64(rootfsGiB) << 30
	}

	/// 寫進別名表的條目。
	public var manifestEntry: LinuxImageManifest.Entry {
		.init(reference: reference, rootfsGiB: rootfsGiB)
	}

	/// 燒製時刻 → 標籤：`b` 加 UTC 的 `yyyyMMddHHmmss`。
	///
	/// 同一個別名每燒一次換一個標籤，舊映像仍可用舊參照取回；以時刻為名，看參照就知道是哪一次燒的。
	///
	/// - Parameter date: 燒製時刻。
	/// - Returns: 標籤。
	public static func tag(for date: Date) -> String {
		let formatter: DateFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		formatter.dateFormat = "yyyyMMddHHmmss"
		return "b" + formatter.string(from: date)
	}

	// MARK: Internal

	/// 設定腳本在容器裡的落點。放在 `/tmp` 下：匯出時 `/tmp` 的內容不進映像。
	internal static let stagedProvisionPath: String = "/tmp/mayfly-bake-provision"

	/// 驗證腳本在容器裡的落點（冒煙容器內，不匯出）。
	internal static let stagedVerifyPath: String = "/tmp/mayfly-bake-verify"

	/// 匯出時不進映像的路徑（相對於 `/`、tar 成員名的形式）。
	///
	/// - `/tmp`、`/var/tmp` 的內容：暫存，包含設定腳本本身。目錄本身留著，權限隨之保留。
	/// - `/etc/resolv.conf`：容器接網路時由執行環境寫進 rootfs，屬於燒製當下那台容器的網路，
	///   下一台容器起來時會再寫一次。
	internal static let excludedMembers: [String] = [
		"./tmp/*",
		"./var/tmp/*",
		"./etc/resolv.conf"
	]

	/// 把整個 rootfs 匯成 tar、寫到 stdout 的命令（GNU tar）。
	///
	/// - `--one-file-system`：`/proc`、`/sys`、`/dev` 這類掛上來的檔案系統不進映像，掛載點目錄本身留著。
	/// - `--numeric-owner`：照 uid／gid 數字記，不經名稱轉換。
	/// - `--xattrs`：保留延伸屬性（file capabilities 存在這裡）。
	internal static var exportArguments: [String] {
		var arguments: [String] = [
			"tar",
			"--create",
			"--file=-",
			"--one-file-system",
			"--numeric-owner",
			"--xattrs",
			"--directory=/"
		]
		arguments.append(contentsOf: excludedMembers.map { "--exclude=" + $0 })
		arguments.append(".")
		return arguments
	}

	/// 確認容器裡的 tar 是 GNU tar 的命令；stdout 須含 ``gnuTarMarker``。
	internal static let tarVersionArguments: [String] = ["tar", "--version"]

	/// GNU tar `--version` 第一行的字樣。busybox tar 不認 ``exportArguments`` 的幾個選項。
	internal static let gnuTarMarker: String = "GNU tar"

	/// 把 stdin 寫成一個可執行檔：`$0` 是落點。
	/// - Parameter path: 落點。
	/// - Returns: argv。
	internal static func stageArguments(path: String) -> [String] {
		["/bin/sh", "-c", #"cat > "$0" && chmod 0700 "$0""#, path]
	}

	/// 以登入 shell 執行一支已落地的腳本。
	/// - Parameter path: 腳本落點。
	/// - Returns: argv。
	internal static func runScriptArguments(path: String) -> [String] {
		["/bin/bash", "-l", path]
	}

	/// 新映像起來之後逐條驗的硬需求（對應 `Containers/README.md`〈映像要滿足的條件〉）。
	///
	/// `HOME` 那一條驗的是 `/etc/passwd` 裡 root 的家目錄有值：這裡的命令不帶映像 config 的
	/// 環境變數，直接看 `$HOME` 驗不到映像本身。
	internal static let smokeScript: String = """
		set -eux
		[ "$(id -un)" = root ]
		[ "$(uname -m)" = aarch64 ]
		[ -n "$(awk -F: '$1 == "root" { print $6 }' /etc/passwd)" ]
		[ -x /bin/sh ]
		command -v git
		[ -s /etc/ssl/certs/ca-certificates.crt ]
		[ -x /bin/true ]
		[ -x /bin/sleep ]
		printf x | base64 | base64 -d
		command -v dirname
		command -v chmod
		umask 077
		mkdir -p /tmp/mayfly-smoke/files
		touch /tmp/mayfly-smoke/files/probe
		"""

	/// 冒煙的 argv：以登入 shell 跑 ``smokeScript``。
	internal static var smokeArguments: [String] {
		["/bin/bash", "-lc", smokeScript]
	}

	// MARK: Private

	/// bytes → 整數 GiB；不是整 GiB 時無條件進位，免得新別名比 base 小。
	/// - Parameter bytes: bytes；`nil` 原樣回。
	/// - Returns: GiB。
	private static func wholeGiB(_ bytes: UInt64?) -> Int? {
		guard let bytes else { return nil }
		let gib: UInt64 = (bytes >> 30) + (bytes & ((1 << 30) - 1) == 0 ? 0 : 1)
		return Int(exactly: gib)
	}
}

// MARK: - + CustomStringConvertible

extension LinuxImageBakePlan.PlanError: CustomStringConvertible {

	/// 人讀訊息。
	public var description: String {
		switch self {
		case let .invalidAlias(alias):
			"alias \"\(alias)\" cannot be used: it must match [A-Za-z0-9][A-Za-z0-9._-]* and form a valid image name"
		case let .aliasExists(alias):
			"alias \"\(alias)\" already exists in the linux image manifest; pass the replace option to overwrite it"
		case let .aliasCaseClash(alias, existing):
			"alias \"\(alias)\" differs from existing alias \"\(existing)\" only in case; both map to the same image name"
		case let .invalidRootfsSize(size):
			"rootfs size \(size) GiB is out of range"
		}
	}
}
