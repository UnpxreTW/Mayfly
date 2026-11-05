//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``LinuxImageBaker/bake(plan:provisionScript:verifyScript:options:)`` 的產物。
public struct LinuxImageBakeResult: Sendable, Equatable {

	/// 新映像在 image store 裡的參照。
	public let reference: String

	/// 新映像 manifest 的 digest。
	public let manifestDigest: String

	/// 唯一那一層的位元組數。
	public let layerSize: Int64

	/// 寫入的別名表。
	public let manifestURL: URL
}
