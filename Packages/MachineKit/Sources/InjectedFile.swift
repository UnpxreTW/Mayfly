//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一筆「要寫進 guest 卷的檔案」的純值描述：內容 + 相對路徑 + owner / mode。
///
/// 本型別只描述「該寫什麼、寫到哪、什麼權限」，不執行任何寫入——實際落地由之後
/// 的離線注入階段（host 掛載 guest Data 卷後）拿這份描述去寫。把「產生內容」與
/// 「寫入」拆開，讓內容產生器（``DslocalUser`` / ``SetupAssistantSkip``）完全不碰
/// IO、可純紙上單測。
public struct InjectedFile: Sendable {

	/// 相對 guest 檔案系統根（`/`）的路徑、不含前導斜線（如
	/// `private/var/db/.AppleSetupDone`）。寫入端會接到實際掛載點之後。
	public var relativePath: String

	/// 檔案內容。
	public var contents: Data

	/// 落地後的擁有者。用 numeric id——寫入端走 `/usr/sbin/chown <uid>:<gid>`，
	/// 因為 `FileManager.setAttributes` 在外來 APFS 卷上會失敗。
	public var owner: (uid: Int, gid: Int)

	/// 落地後的權限模式（如 `0o600`）。
	public var mode: mode_t

	public init(relativePath: String, contents: Data, owner: (uid: Int, gid: Int), mode: mode_t) {
		self.relativePath = relativePath
		self.contents = contents
		self.owner = owner
		self.mode = mode
	}
}
