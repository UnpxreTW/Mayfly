//
//  MayflyUI
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// GUI 看到的 daemon 端點快照：socket 落點與該落點當下是否存在。
///
/// 刻意做成純值型別＋注入式解析（環境變數與檔案存在性都由呼叫端給），View 層只消費結果、
/// 不自行碰檔案系統——外殼因此可在無 daemon 的機器上被測到。存在性**不等於連得上**
/// （殘留 socket 檔亦存在），真正的連線判定留給 ``NymphClient``。
public struct DaemonEndpoint: Sendable, Equatable {

	/// Unix domain socket 的檔案系統路徑。
	public let socketPath: String

	/// 該路徑當下是否存在。
	public let isSocketPresent: Bool

	public init(socketPath: String, isSocketPresent: Bool) {
		self.socketPath = socketPath
		self.isSocketPresent = isSocketPresent
	}

	/// 以 ``NymphPaths`` 的落點慣例解析出當下端點。
	///
	/// - Important: 預設的行程環境對 app bundle 只在從終端啟動時有意義——由 Finder／Dock 啟動時
	///   繼承的是 launchd 環境、讀不到 shell 匯出的 `MAYFLY_STATE_DIR`，解析結果會退回預設落點。
	///   因此「socket 不存在」只代表**預設落點**沒有 socket，不等於沒有 daemon 在跑；由 daemon
	///   自報實際落點的端點探索留後續切片。
	///
	/// - Parameters:
	///   - environment: 供 `MAYFLY_STATE_DIR` 覆寫解析，預設取當前行程環境。
	///   - fileExists: 存在性判定，預設走 `FileManager.default`。
	public static func resolve(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
	) -> DaemonEndpoint {
		let path = NymphPaths.socketURL(environment: environment).path(percentEncoded: false)
		return DaemonEndpoint(socketPath: path, isSocketPresent: fileExists(path))
	}
}
