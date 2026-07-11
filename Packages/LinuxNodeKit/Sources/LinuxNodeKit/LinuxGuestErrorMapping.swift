//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import NymphKit

/// ``ContainerizationError`` → ``NymphError`` 的映射正本（M1 契約：錯誤映射進
/// `NymphError` 既有 case 系，不新開錯誤面）。純值轉換、arch-neutral（``ContainerizationError``
/// 本身不含 arch 限定符號）——可離開真容器單測，``LinuxGuestControl`` 只是呼叫端。
enum LinuxGuestErrorMapping {

	/// 把 Containerization 層的錯誤收斂進既有 ``NymphError`` case：
	/// - `.timeout` → ``NymphError/execTimedOut``（1:1，`wait(timeoutInSeconds:)` 逾時的
	///   documented 行為）。
	/// - `.notFound` / `.invalidState` → ``NymphError/notReady``（容器目前不可定址 /
	///   狀態不對，屬「無法連入執行」同一類）。
	/// - `.cancelled` / `.interrupted` → ``NymphError/transportFailure(_:)``（執行通道
	///   中途被打斷，同 macOS 線「SSH 傳輸層失敗」的錯誤面）。
	/// - 其餘（`.internalError` / `.unknown` / `.exists` / `.invalidArgument` /
	///   `.unsupported` / `.empty`）→ ``NymphError/internalFailure(_:)``（既有的
	///   「其餘未歸類的內部錯誤」catch-all）。
	/// - 非 ``ContainerizationError``（如 `URLSession` / `Process` 失敗）→
	///   ``NymphError/transportFailure(_:)``。
	static func map(_ error: any Error) -> NymphError {
		guard let containerizationError = error as? ContainerizationError else {
			return .transportFailure(String(describing: error))
		}
		switch containerizationError.code {
		case .timeout:
			return .execTimedOut

		case .notFound, .invalidState:
			return .notReady

		case .cancelled, .interrupted:
			return .transportFailure(containerizationError.message)

		default:
			return .internalFailure(containerizationError.message)
		}
	}
}