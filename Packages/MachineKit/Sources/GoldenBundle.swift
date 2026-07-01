//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 已 provisioned 的 guest bundle marker。與「剛裝好、未注入」的裸 bundle 在型別上區隔
/// ——run 路徑可在編譯期要求一份「保證 provisioning 跑過」的 image，延續 create-vs-load
/// 的型別紀律（再加一層 provisioned-vs-unprovisioned）。
///
/// `init` 不公開：只有同模組的 ``GuestProvisioner`` 鑄得出 GoldenBundle，下游模組
/// （CLI / app / MCP）拿不到鑄造途徑、只能消費——這正是型別層保證的來源。
public struct GoldenBundle: Sendable {

	/// 已注入完成的 guest bundle 目錄。
	public let bundle: URL
}
