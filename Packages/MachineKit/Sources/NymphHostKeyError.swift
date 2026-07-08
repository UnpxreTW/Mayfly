//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``NymphHostKey`` 與其產生器（``NymphKeyGenerator``）的失敗情形。
public enum NymphHostKeyError: Error, Equatable, Sendable {

	/// `ssh-keygen`（或注入的產生器）非零退出。帶結束碼與 stderr。
	case keygenFailed(status: Int32, stderr: String)

	/// 公鑰檔存在卻讀不到（權限 / 編碼）。
	case publicKeyUnreadable(URL)

	/// 公鑰檔可讀但內容為空——不成一條 authorized_keys 條目。
	case publicKeyEmpty(URL)
}
