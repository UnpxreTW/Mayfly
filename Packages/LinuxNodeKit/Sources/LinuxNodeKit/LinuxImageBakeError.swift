//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 燒製失敗的階段。
///
/// 每個 case 都說在哪一步停下：設定腳本跑了幾十分鐘後失敗，操作者要的第一個資訊是「是腳本本身、
/// 匯出、還是新映像起不來」。
public enum LinuxImageBakeError: Error, Equatable {

	/// 容器在 readiness 上限內沒有起來。
	case guestNotReady(stage: String)

	/// 把腳本寫進容器失敗（結束碼）。
	case stagingFailed(exitCode: Int32)

	/// 設定腳本以非 0 結束。
	case provisionFailed(exitCode: Int32)

	/// 容器裡沒有 GNU tar（匯出要用它的選項）。
	case tarNotGNU

	/// 匯出 rootfs 的 tar 以非 0 結束。
	case exportFailed(exitCode: Int32)

	/// 匯出的 tar 寫到本機時失敗，或一個位元組都沒寫出來。
	case exportIncomplete(reason: String)

	/// 新映像的冒煙檢查沒過（結束碼）。
	case smokeFailed(exitCode: Int32)

	/// 呼叫端給的驗證腳本沒過（結束碼）。
	case verifyFailed(exitCode: Int32)

	/// 燒製被中途停下。
	case stopped
}

extension LinuxImageBakeError: CustomStringConvertible {

	/// 人讀訊息。
	public var description: String {
		switch self {
		case let .guestNotReady(stage):
			"\(stage) container did not become ready in time"
		case let .stagingFailed(exitCode):
			"copying a script into the container failed (exit \(exitCode))"
		case let .provisionFailed(exitCode):
			"provision script failed (exit \(exitCode))"
		case .tarNotGNU:
			"the base image has no GNU tar; install it in the provision script (e.g. apk add tar)"
		case let .exportFailed(exitCode):
			"exporting the root filesystem failed (tar exit \(exitCode))"
		case let .exportIncomplete(reason):
			"exporting the root filesystem failed: \(reason)"
		case let .smokeFailed(exitCode):
			"the baked image failed the smoke check (exit \(exitCode)); it was removed from the image store"
		case let .verifyFailed(exitCode):
			"the verify script failed on the baked image (exit \(exitCode)); it was removed from the image store"
		case .stopped:
			"bake was stopped"
		}
	}
}
