//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MayflyUI
import Testing

// MARK: - DaemonEndpointTests

private final class DaemonEndpointTests {

	/// state dir 覆寫時，socket 落點跟著覆寫走。
	@Test
	private func `resolve honours state directory override`() {
		let endpoint: DaemonEndpoint = .resolve(
			environment: ["MAYFLY_STATE_DIR": "/tmp/mayfly-endpoint-test"],
			fileExists: { _ in false }
		)
		#expect(endpoint.socketPath == "/tmp/mayfly-endpoint-test/nymph.sock")
	}

	/// 無覆寫時落在家目錄下的 `.mayfly/nymph.sock`。
	@Test
	private func `resolve falls back to home state directory`() {
		let expected: String = FileManager.default.homeDirectoryForCurrentUser
			.appending(component: ".mayfly")
			.appending(component: "nymph.sock")
			.path(percentEncoded: false)
		let endpoint: DaemonEndpoint = .resolve(environment: [:], fileExists: { _ in false })
		#expect(endpoint.socketPath == expected)
	}

	/// 存在性由注入的判定決定、且判定收到的正是解析出的路徑。
	@Test
	private func `resolve reports presence from injected probe`() {
		var probed: [String] = []
		let endpoint: DaemonEndpoint = .resolve(
			environment: ["MAYFLY_STATE_DIR": "/tmp/mayfly-endpoint-test"],
			fileExists: { path in
				probed.append(path)
				return true
			}
		)
		#expect(endpoint.isSocketPresent)
		#expect(probed == ["/tmp/mayfly-endpoint-test/nymph.sock"])
	}
}
