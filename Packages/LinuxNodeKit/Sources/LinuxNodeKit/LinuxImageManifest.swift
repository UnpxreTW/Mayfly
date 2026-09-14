//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 操作者手寫的 Linux 別名表：alias → OCI image 參照 ＋ 那個別名要配多大的 rootfs。
///
/// 內建別名表（``LinuxImageResolver/defaultAliases``）編在 binary 裡、只夠冒煙；真正要跑
/// job 的映像是換版就要換一次參照的東西，把它釘在原始碼裡等於每換一顆映像就得重出一版
/// binary。改成讀一份檔，換映像只要改檔、重啟 daemon。
///
/// 格式（`version` 目前只收 `1`）：
///
/// ```json
/// {
///   "version": 1,
///   "images": {
///     "ci-lint": {
///       "reference": "ghcr.io/unpxretw/mayfly-ci-lint@sha256:...",
///       "rootfsGiB": 4
///     }
///   }
/// }
/// ```
///
/// - Important: 別名只收 `[A-Za-z0-9][A-Za-z0-9._-]*`——含 `/` 或 `:` 的字串會被
///   ``LinuxImageResolver`` 的 passthrough 規則先接走，這種條目寫在檔裡永遠打不到，
///   所以在解析時就擋下、不留到 spawn 當下才變成一個查不出原因的「別名沒生效」。
/// - Note: 未知的鍵一律忽略（`Codable` 預設），檔案多寫東西不會讓既有部署起不來。
public struct LinuxImageManifest: Codable, Sendable, Equatable {

	// MARK: Public

	/// 別名表的一條：要拉哪顆映像、rootfs 配多大。
	public struct Entry: Codable, Sendable, Equatable {

		/// OCI image 參照，原樣交給容器層。
		///
		/// - Important: 生產用的別名寫 digest 形（`@sha256:`）。程式不強制——tag 形留給冒煙與
		///   開發——但 `latest` 之類的 tag 會被下一次推蓋掉，同一份設定在不同時間點會拉到不同
		///   的東西。
		public let reference: String

		/// rootfs 上限（GiB）；省略＝用引擎預設。
		///
		/// 要配多大取決於映像裡有什麼：只跑靜態檢查的映像與帶整套工具鏈的映像差一個量級，
		/// 這是 per-alias 的事實、不是一個全域值調得動的。
		public let rootfsGiB: Int?

		/// - Parameters:
		///   - reference: OCI image 參照。
		///   - rootfsGiB: rootfs 上限（GiB）；`nil`＝用引擎預設。
		public init(reference: String, rootfsGiB: Int? = nil) {
			self.reference = reference
			self.rootfsGiB = rootfsGiB
		}

		/// ``rootfsGiB`` 換算成 bytes；`nil`＝這個別名沒指定、由引擎決定。
		public var rootfsSizeInBytes: UInt64? {
			guard let rootfsGiB: Int = rootfsGiB else { return nil }
			return UInt64(rootfsGiB) << 30
		}
	}

	/// 讀取或驗證一份別名表時的失敗面。
	///
	/// 每個 case 都帶檔案路徑：這份檔是操作者手寫的，訊息裡沒有路徑時，機器上有好幾個
	/// golden root 的人得先猜是哪一份檔壞了。
	public enum LoadError: Error, Equatable {

		/// 檔案在、但不是能解的 JSON（或欄位型別對不上）。
		case malformedJSON(path: String, reason: String)

		/// `version` 不是這版程式認得的值——格式換代時寧可拒收，也不要照舊欄位半解。
		case unsupportedVersion(path: String, version: Int)

		/// 別名不符允許的字元集（見型別說明的 `- Important:`）。
		case invalidAlias(path: String, alias: String)

		/// `reference` 是空字串——容器層拿空參照只會在 spawn 當下失敗，這裡先擋。
		case emptyReference(path: String, alias: String)

		/// `rootfsGiB` 不是正整數、或大到換算成 bytes 會溢位。
		case invalidRootfsSize(path: String, alias: String)
	}

	/// 這版程式認得的格式版本。
	public static let currentVersion: Int = 1

	/// 別名表的檔名（落在 golden root 之下，見 ``LinuxNodePaths/imageManifestURL(environment:)``）。
	public static let fileName: String = "linux-images.json"

	/// 格式版本。
	public let version: Int

	/// alias → 那個別名的內容。
	public let images: [String: Entry]

	/// - Parameters:
	///   - version: 格式版本。
	///   - images: alias → 別名內容。
	public init(version: Int, images: [String: Entry]) {
		self.version = version
		self.images = images
	}

	/// 讀一份別名表：讀檔 → 解 JSON → 驗版本與各條目，四步都過才回。
	///
	/// - Parameter url: 別名表路徑。
	/// - Returns: 驗過的別名表。
	/// - Throws: 讀檔失敗時為 `Foundation` 的檔案錯誤；其餘為 ``LoadError``。
	public static func load(from url: URL) throws -> LinuxImageManifest {
		let data: Data = try Data(contentsOf: url)
		let manifest: LinuxImageManifest
		do {
			manifest = try JSONDecoder().decode(LinuxImageManifest.self, from: data)
		} catch {
			throw LoadError.malformedJSON(path: url.path, reason: "\(error)")
		}
		try manifest.validate(path: url.path)
		return manifest
	}

	// MARK: Private

	/// 驗版本與每一條目；訊息帶路徑，所以驗證要知道自己是從哪個檔來的。
	/// - Parameter path: 這份表的來源路徑，只用於錯誤訊息。
	/// - Throws: ``LoadError``。
	private func validate(path: String) throws {
		guard version == LinuxImageManifest.currentVersion else {
			throw LoadError.unsupportedVersion(path: path, version: version)
		}
		for (alias, entry) in images {
			guard LinuxImageManifest.isValidAlias(alias) else { throw LoadError.invalidAlias(path: path, alias: alias) }
			guard !entry.reference.isEmpty else { throw LoadError.emptyReference(path: path, alias: alias) }
			if let rootfsGiB: Int = entry.rootfsGiB {
				guard
					rootfsGiB > 0,
					UInt64(rootfsGiB) <= UInt64.max >> 30
				else { throw LoadError.invalidRootfsSize(path: path, alias: alias) }
			}
		}
	}

	/// 別名是否符合 `[A-Za-z0-9][A-Za-z0-9._-]*`。
	/// - Parameter alias: 待驗的別名。
	/// - Returns: 合規為 `true`。
	private static func isValidAlias(_ alias: String) -> Bool {
		guard
			let first: Character = alias.first,
			LinuxImageManifest.isASCIIAlphanumeric(first)
		else { return false }
		return alias.allSatisfy { character in
			LinuxImageManifest.isASCIIAlphanumeric(character) || ".-_".contains(character)
		}
	}

	/// 是否為 ASCII 的英數字元。
	///
	/// 不單用 `isLetter`／`isNumber`：那兩個對全形數字與各種文字系統的字母都回 `true`，
	/// 而這裡要的是能安全出現在別名與容器參照裡的那一小撮字元。
	/// - Parameter character: 待判的字元。
	/// - Returns: 是 ASCII 英數字元為 `true`。
	private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
		character.isASCII && (character.isLetter || character.isNumber)
	}
}

extension LinuxImageManifest.LoadError: CustomStringConvertible {

	/// 人讀訊息：每一種失敗都先報哪一份檔，再說壞在哪裡——操作者拿到訊息就能直接去改那份檔。
	public var description: String {
		switch self {
		case .malformedJSON(let path, let reason):
			"linux image manifest \(path) could not be parsed: \(reason)"

		case .unsupportedVersion(let path, let version):
			"""
			linux image manifest \(path) has version \(version); \
			this build only accepts version \(LinuxImageManifest.currentVersion)
			"""

		case .invalidAlias(let path, let alias):
			"""
			linux image manifest \(path) has invalid alias "\(alias)"; \
			aliases must match [A-Za-z0-9][A-Za-z0-9._-]* (no "/" or ":")
			"""

		case .emptyReference(let path, let alias):
			"linux image manifest \(path) has an empty reference for alias \"\(alias)\""

		case .invalidRootfsSize(let path, let alias):
			"linux image manifest \(path) has an out-of-range rootfsGiB for alias \"\(alias)\""
		}
	}
}
