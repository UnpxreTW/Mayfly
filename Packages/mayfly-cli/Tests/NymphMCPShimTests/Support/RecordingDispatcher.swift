//
//  NymphMCPShimTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import NymphKit

/// 假分派器：回固定回應、記錄收到的請求——讓測試把一個真 ``NymphServer``（監聽真 Unix
/// socket）接上，`NymphMCPShim` 經 ``NymphKit/NymphClient`` 跟它對話，脫離真 daemon /
/// `SessionStore` / 真 VM（鏡射 `NymphKitTests` 的 `FakeDispatcher`，同一測試模式）。
actor RecordingDispatcher: RequestDispatching {

	init(response: NymphResponse) {
		self.response = response
	}

	private(set) var received: [NymphRequest] = []

	func handle(_ request: NymphRequest) async -> NymphResponse {
		received.append(request)
		return response
	}

	private let response: NymphResponse
}
