//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// Linux 節點狀態落點——沿用 NymphKit 的 state dir 正本（``NymphPaths/stateDirectory(environment:)``，
/// 單一真相、不另開一套路徑慣例）。容器 image store／rootfs 落 `<stateDir>/linux`；
/// kernel 快取落 `<stateDir>/kernels`（`~/.mayfly/kernels/`）。
public enum LinuxNodePaths {

	/// 容器 image store / rootfs 根目錄（`<stateDir>/linux`）。
	public static func containerRoot(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		NymphPaths.stateDirectory(environment: environment).appending(component: "linux")
	}

	/// kernel 快取根目錄（`<stateDir>/kernels`）。
	public static func kernelCacheDirectory(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		NymphPaths.stateDirectory(environment: environment).appending(component: "kernels")
	}

	/// 操作者維護的 Linux 別名表（`<goldenRoot>/linux-images.json`）。
	///
	/// 跟著 golden root 走、不另開一個環境變數：macOS 的 golden 與 Linux 的別名由同一個
	/// 操作者維護，兩者分兩個家只是多一個會設錯、也會忘記一起搬的旋鈕。
	///
	/// - Parameter environment: 解析 golden root 用的環境變數。
	/// - Returns: 別名表路徑；停用別名模式（無 golden root）時為 `nil`。
	public static func imageManifestURL(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL? {
		GoldenResolver.fromEnvironment(environment: environment)
			.goldenRoot?
			.appending(component: LinuxImageManifest.fileName)
	}
}
