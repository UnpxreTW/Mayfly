//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``GoldenBundle/load(from:)`` 的失敗情形。
public enum GoldenBundleError: Error, Equatable {

	/// bundle 佈局缺件（五件套之一不存在），附缺的那個檔案位置。
	case missingComponent(URL)

	/// `metadata.json` 存在但解不開（毀損或非本格式）。
	case metadataUndecodable(URL)
}
