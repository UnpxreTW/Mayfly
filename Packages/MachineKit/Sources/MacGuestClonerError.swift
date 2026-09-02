//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``MacGuestCloner`` 的失敗情形。`clonefile(2)` 的 errno 映射成可判別的 case：
/// 呼叫端能區分「換個目的地就好」（``destinationExists(_:)``）與「佈局違反
/// 同卷契約、需人為介入」（``crossVolume(source:destination:)``）。
public enum MacGuestClonerError: Error, Equatable {

	/// 來源 bundle 不存在（`ENOENT` 且來源查無）。
	case sourceMissing(URL)

	/// 目的地的父目錄不存在（`ENOENT` 且來源存在）。`clonefile(2)` 對「來源不存在」
	/// 與「目的地路徑前綴不存在」回同一個 ENOENT，光看 errno 分不出來；cloner 不替
	/// 呼叫端 `mkdir`，per-job 工作目錄該由呼叫端備妥。
	case destinationParentMissing(URL)

	/// 目的地已存在（`EEXIST`）——clone 絕不覆蓋，收掉舊複本或換名是呼叫端的決定。
	case destinationExists(URL)

	/// 來源與目的地不在同一卷（`EXDEV`）。copy-on-write 只在同一 APFS 卷內成立，
	/// 跨卷是佈局錯誤、不退化成完整複製。
	case crossVolume(source: URL, destination: URL)

	/// 檔案系統不支援 clone（`ENOTSUP`，非 APFS）。
	case copyOnWriteUnsupported(URL)

	/// 其他 `clonefile(2)` 失敗，保留原始 errno 供 triage。
	case cloneFailed(errno: Int32)

	// MARK: Internal

	/// 把 `clonefile(2)` 的 errno 映射成型別化錯誤。ENOENT 語義雙關（來源缺 vs
	/// 目的地父目錄缺），由呼叫端以 `sourceExists`（事後 stat、供 triage 用、容忍
	/// TOCTOU）消歧。
	static func map(errno code: Int32, source: URL, destination: URL, sourceExists: Bool) -> MacGuestClonerError {
		switch code {
		case ENOENT:
			sourceExists ? .destinationParentMissing(destination) : .sourceMissing(source)

		case EEXIST:
			.destinationExists(destination)

		case EXDEV:
			.crossVolume(source: source, destination: destination)

		case ENOTSUP:
			.copyOnWriteUnsupported(destination)

		default:
			.cloneFailed(errno: code)
		}
	}
}
