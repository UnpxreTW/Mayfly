//
//  NymphMCPShimTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 短 socket 路徑（`sun_path` 上限 104；用 `/tmp` 避免 temp dir 過長）——鏡射
/// `NymphServerTests` 的同名 helper。
func temporarySocketURL() -> URL {
	URL(fileURLWithPath: "/tmp/nymph-mcp-\(UUID().uuidString.prefix(8)).sock")
}
