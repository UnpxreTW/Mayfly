//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// RAW sparse 開機磁碟的建立。
///
/// VZ 只收 RAW data disk image，且檔長須為 512 bytes 整數倍——未對齊會被
/// `VZDiskImageStorageDeviceAttachment` 的建構 / config 驗證層擋下
/// （`VZErrorInvalidDiskImage`、確切失敗點由實際建 attachment 的切片驗證），
/// 這裡先擋掉對齊問題給清楚的錯誤、不拖到那層才爆。任何 `× 1024` 的 GiB 名目
/// 本就對齊。APFS 上 `truncate` 撐出的洞完全 sparse、實佔 0，install 過程才
/// materialize 真正寫到的 block。
public enum BootDiskImage {

	/// 建立 RAW sparse 開機磁碟時的錯誤。
	public enum Error: Swift.Error {

		/// 目標已存在、且未要求覆寫。
		case alreadyExists(URL)

		/// 建立空檔失敗：路徑不可寫、父目錄不存在、或目標是既有目錄。
		/// `FileManager.createFile` 只回 Bool、拿不到 errno，故不帶底層成因；
		/// bundle 目錄須由呼叫端先建好。
		case createFailed(URL)

		/// 名目大小非 512 bytes 的正整數倍（含 0）——不是合法的 RAW 磁碟長度。
		case misalignedSize(UInt64)
	}

	/// VZ 要求的磁碟長度對齊單位。
	public static let blockSize: UInt64 = 512

	/// 預設名目大小 64GiB。base macOS（不裝 Xcode）實佔 ~15-20GB，sparse 下名目
	/// 大幾乎零代價（實佔按寫入 block 走）；要裝 Xcode 的 image 再開到 128GiB。
	public static let defaultNominalBytes: UInt64 = 64 * 1024 * 1024 * 1024

	/// 在 `url` 建一顆名目 `nominalBytes` 的空 sparse RAW 磁碟。
	///
	/// `overwrite` 為 `false` 且檔已存在則擲 ``Error/alreadyExists(_:)``（保護既有
	/// bundle、避免覆掉裝好的 guest）。大小未對齊 512 bytes 擲
	/// ``Error/misalignedSize(_:)``。
	public static func create(
		at url: URL,
		nominalBytes: UInt64 = defaultNominalBytes,
		overwrite: Bool = false
	) throws {
		guard nominalBytes >= blockSize, nominalBytes % blockSize == 0 else {
			throw Error.misalignedSize(nominalBytes)
		}
		let manager: FileManager = .default
		if manager.fileExists(atPath: url.path) {
			guard overwrite else {
				throw Error.alreadyExists(url)
			}
		}
		// createFile 在檔已存在時截斷重建，對 overwrite 路徑剛好；回 false = 不可寫。
		guard manager.createFile(atPath: url.path, contents: nil) else {
			throw Error.createFailed(url)
		}
		// createFile 成功後 open / truncate 若失敗（disk-full、EFBIG…）會留一顆
		// 0-byte 殘檔——移除再上拋，讓 create 對外 all-or-nothing；否則殘檔會被
		// 後續非 overwrite 的 create 誤判成 alreadyExists。
		do {
			let handle: FileHandle = try .init(forWritingTo: url)
			defer { try? handle.close() }
			try handle.truncate(atOffset: nominalBytes)
		} catch {
			try? manager.removeItem(at: url)
			throw error
		}
	}
}
