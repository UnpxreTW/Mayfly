//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - ExecOutputParams

/// execOutput 參數。
public struct ExecOutputParams: Codable, Sendable, Equatable {

	/// 背景 exec 的 id（``ExecSubmitResult/execID``）。
	public let execID: String

	/// 每條串流只回最後這麼多 bytes；nil＝回目前保留的全部。
	public let tailBytes: Int?

	/// 建立 execOutput 參數。
	/// - Parameters:
	///   - execID: 背景 exec 的 id。
	///   - tailBytes: 每條串流只回最後這麼多 bytes；nil＝全部。
	public init(execID: String, tailBytes: Int? = nil) {
		self.execID = execID
		self.tailBytes = tailBytes
	}
}
