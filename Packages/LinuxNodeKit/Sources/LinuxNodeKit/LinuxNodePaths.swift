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
}
