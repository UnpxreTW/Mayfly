//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// 把 binary plist bytes 解回 `[String: Any]`，供測試斷言結構。
func decodePlist(_ data: Data) throws -> [String: Any] {
	let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
	return try #require(object as? [String: Any], "plist 根層應為字典")
}
