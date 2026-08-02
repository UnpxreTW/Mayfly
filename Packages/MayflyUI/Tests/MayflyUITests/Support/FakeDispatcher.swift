//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

/// 真 socket 整合測試用的伺服端替身：收下請求、記起來、回一份講好的回應。
///
/// 有它才能在沒有 daemon（也不碰 VM）的機器上把整條線走完——編碼、換行分隔、連線收束
/// 都是真的，只有分派器是假的。
actor FakeDispatcher: RequestDispatching {

	// MARK: Internal

	init(response: NymphResponse) {
		self.response = response
	}

	/// 依序收到的請求。
	private(set) var received: [NymphRequest] = []

	func handle(_ request: NymphRequest) async -> NymphResponse {
		received.append(request)
		return response
	}

	// MARK: Private

	private let response: NymphResponse
}
