//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Containerization
import Foundation

// Writer 是 Containerization 的 IO 協定，隨真容器 API 一起 arch gate（比照
// BufferedOutputWriter.swift）。

#if arch(arm64)

/// 把收到的位元組原樣交給 `forward` 的 ``Writer``：容器內命令的輸出即時轉給操作者。
internal struct OutputForwardingWriter: Writer {

	/// 輸出的去處。
	internal let forward: @Sendable (Data) -> Void

	/// 把一段輸出交給 ``forward``。
	/// - Parameter data: 輸出的位元組。
	internal func write(_ data: Data) throws {
		forward(data)
	}

	/// 無資源可收。
	internal func close() throws {}
}

#endif
