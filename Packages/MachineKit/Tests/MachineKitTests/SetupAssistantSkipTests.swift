//
//  MachineKitTests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import MachineKit
import Foundation
import Testing

private final class SetupAssistantSkipTests {

	/// 六概念層、共七檔（第六層含兩個 lproj），路徑互異。
	@Test
	private func `layers are seven distinct files`() throws {
		let layers = try SetupAssistantSkip.layers(forUser: "runner", uid: 501)
		#expect(layers.count == 7)
		#expect(Set(layers.map(\.relativePath)).count == 7, "路徑應互異")
	}

	/// `.AppleSetupDone`：root:wheel、0600、空內容（presence gates、mode 非 0400）。
	@Test
	private func `apple setup done owner and mode`() throws {
		let layers = try SetupAssistantSkip.layers(forUser: "runner", uid: 501)
		let marker = try #require(layers.first { $0.relativePath == "private/var/db/.AppleSetupDone" })
		#expect(marker.owner.uid == 0)
		#expect(marker.owner.gid == 0)
		#expect(marker.mode == 0o600)
		#expect(marker.contents.isEmpty)
	}

	/// per-user 偏好：路徑帶 user、owner = (uid, staff)、0600。
	@Test
	private func `per user preference ownership`() throws {
		let layers = try SetupAssistantSkip.layers(forUser: "runner", uid: 501)
		let path = "Users/runner/Library/Preferences/com.apple.SetupAssistant.plist"
		let perUser = try #require(layers.first { $0.relativePath == path })
		#expect(perUser.owner.uid == 501)
		#expect(perUser.owner.gid == 20)
		#expect(perUser.mode == 0o600)
	}

	/// system-wide DidSee* 偏好內容：旗標為 true、GestureMovieSeen 為 none。
	@Test
	private func `did see preference contents`() throws {
		let layers = try SetupAssistantSkip.layers(forUser: "runner", uid: 501)
		let path = "Library/Preferences/com.apple.SetupAssistant.plist"
		let system = try #require(layers.first { $0.relativePath == path })
		let didSee = try decodePlist(system.contents)
		#expect(didSee["DidSeePrivacy"] as? Bool == true)
		#expect(didSee["DidSeeCloudSetup"] as? Bool == true)
		#expect(didSee["GestureMovieSeen"] as? String == "none")
	}

	/// managed Skip* 偏好內容：旗標皆 true。
	@Test
	private func `managed skip preference contents`() throws {
		let layers = try SetupAssistantSkip.layers(forUser: "runner", uid: 501)
		let path = "Library/Preferences/com.apple.SetupAssistant.managed.plist"
		let managed = try #require(layers.first { $0.relativePath == path })
		let skip = try decodePlist(managed.contents)
		#expect(skip["SkipCloudSetup"] as? Bool == true)
		#expect(skip["SkipSiriSetup"] as? Bool == true)
		#expect(skip["SkipPrivacySetup"] as? Bool == true)
	}
}
