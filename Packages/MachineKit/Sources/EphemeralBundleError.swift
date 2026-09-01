//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``EphemeralBundle/load(from:)`` 的失敗情形。
public enum EphemeralBundleError: Error, Equatable {

	/// bundle 佈局缺件（五件套之一不存在），附缺的那個檔案位置。
	case missingComponent(URL)

	/// `metadata.json` 存在但解不開（毀損或非本格式）。
	case metadataUndecodable(URL)

	/// metadata 沒有 `ephemeral` 標記——不是 ``MacGuestCloner`` 的可拋複本（可能是
	/// golden 或外來 bundle），不得包成可銷毀的 EphemeralBundle。
	case notEphemeral(URL)
}
