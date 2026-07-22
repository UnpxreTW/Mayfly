//
//  LinuxNodeKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LinuxNodeKit
import Foundation
import Testing

// MARK: - LinuxToolchainAlignmentTests

/// vminitd 版本 skew 護欄：`Package.resolved` 解出的 containerization 版本必須與
/// ``LinuxToolchain/containerizationVersion``（vminitd image tag 正本）一致——任一側
/// 單獨升版即 fail，逼迫 exact pin 與常數在同一變更內對齊。
private final class LinuxToolchainAlignmentTests {

	/// `Package.resolved` 的 containerization pin 與工具鏈常數一致。
	@Test
	private func `resolved containerization pin matches toolchain constant`() throws {
		let resolvedURL: URL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent() // LinuxNodeKitTests
			.deletingLastPathComponent() // Tests
			.deletingLastPathComponent() // LinuxNodeKit（package root）
			.appendingPathComponent("Package.resolved")
		let data: Data = try Data(contentsOf: resolvedURL)
		let resolved: ResolvedFile = try JSONDecoder().decode(ResolvedFile.self, from: data)
		let pin: ResolvedFile.Pin = try #require(
			resolved.pins.first { $0.identity == "containerization" }
		)
		#expect(pin.state.version == LinuxToolchain.containerizationVersion)
	}
}

/// `Package.resolved` 的最小解碼形（只取對齊檢查用到的欄位）。
private struct ResolvedFile: Decodable {

	struct Pin: Decodable {

		struct State: Decodable {
			let version: String?
		}

		let identity: String
		let state: State
	}

	let pins: [Pin]
}
