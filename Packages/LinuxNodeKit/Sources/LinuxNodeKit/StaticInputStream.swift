//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation

#if arch(arm64)

/// 把一段固定字串包成一次性 ``ReaderStream``——`exec` 的 `standardInput` 參數轉接用：
/// 單次 yield 全文後即關閉。夠用即可、非通用 stdin pipe（沒有互動式輸入需求）。
struct StaticInputStream: ReaderStream {

	let data: Data

	func stream() -> AsyncStream<Data> {
		AsyncStream { continuation in
			continuation.yield(data)
			continuation.finish()
		}
	}
}

#endif
