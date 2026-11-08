//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - ExecSubmitResult

/// executeDetached 結果。
public struct ExecSubmitResult: Codable, Sendable, Equatable {

	/// 背景 exec 的 id。
	public let execID: String

	/// 建立 executeDetached 結果。
	/// - Parameter execID: 配給這條背景 exec 的 id。
	public init(execID: String) {
		self.execID = execID
	}
}
