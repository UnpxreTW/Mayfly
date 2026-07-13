//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 抓＋驗＋解壓一份 ``LinuxKernelArchive``、把 kernel 二進位落地到 `destination` 的動作。
/// 抽成 protocol 讓 ``LinuxKernelProvisioner`` 的 fetch-on-demand 編排可用假實作單測
/// （不必真連網 / 真解壓）；真機實作見 ``SystemKernelArchiveFetcher``。
public protocol KernelArchiveFetching: Sendable {

	/// 抓 `archive`、驗 sha256、解壓取出 kernel 二進位、寫入 `destination`（呼叫端已保證
	/// parent 目錄存在）。任何步驟失敗即擲錯，不留半成品於 `destination`。
	func fetch(_ archive: LinuxKernelArchive, to destination: URL) async throws
}
