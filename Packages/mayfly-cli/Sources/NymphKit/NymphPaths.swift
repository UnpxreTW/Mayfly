//
//  NymphKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// nymph daemon 的落點慣例單一正本：state dir（穩定身份鑰、clone 登記檔）與 Unix domain
/// socket 路徑——`mayfly nymph`（server）與 daemon-client 動詞（spawn/exec/list/status/destroy）
/// 消費同一組路徑，才連得上同一個 daemon。
///
/// state dir 解析：環境變數 `MAYFLY_STATE_DIR` 覆寫，否則 `~/.mayfly`（短路徑——Unix
/// socket 的 `sun_path` 上限 104 bytes，state dir 過長會讓 socket 綁不起來）。
public enum NymphPaths {

	/// state dir 覆寫用環境變數名。
	public static let stateDirectoryEnvironmentKey = "MAYFLY_STATE_DIR"

	/// 解析 nymph state dir：`MAYFLY_STATE_DIR` 優先、否則 `~/.mayfly`。
	public static func stateDirectory(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		if let override = environment[stateDirectoryEnvironmentKey], !override.isEmpty {
			return URL(fileURLWithPath: override, isDirectory: true)
		}
		return FileManager.default.homeDirectoryForCurrentUser.appending(component: ".mayfly")
	}

	/// Unix domain socket 路徑（`<stateDir>/nymph.sock`）。
	public static func socketURL(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		stateDirectory(environment: environment).appending(component: "nymph.sock")
	}

	/// clone 登記檔路徑（`<stateDir>/clones.registry`；孤兒回收用，見 ``CloneRegistry``）。
	public static func cloneRegistryURL(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		stateDirectory(environment: environment).appending(component: "clones.registry")
	}
}
