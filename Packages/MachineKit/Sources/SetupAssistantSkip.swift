//
//  MachineKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 離線跳過 Setup Assistant 的標記檔產生器。
///
/// 安裝後的 guest 第一次開機會落在 Setup Assistant（要求建帳號、隱私、Apple ID
/// 等互動），整台機器因此 SSH 不到。離線寫入這組標記、搭配 ``DslocalUser`` 建好的
/// 本機帳號，讓 guest 直接跳到登入後狀態。
///
/// 產出純 ``InjectedFile`` 值（內容 + 路徑 + owner / mode）、不寫任何檔案，可純紙上
/// 單測；實際落地由離線注入階段負責。
///
/// **單一來源、需真機 read-back**：`DidSee*` / `Skip*` 的 key 集來自單一非官方來源，
/// 動工後須對真機既有帳號 read-back 校正。第六層 `.skipbuddy` 落在 System 卷
/// （現代 macOS sealed / read-only、且不在 Data 卷 firmlink 清單內）——與「掛載 Data
/// 卷寫入」的假設衝突，可寫性待真機驗證；本型別只忠實列出設計的層、不預判可寫性。
public enum SetupAssistantSkip {

	// MARK: Public

	/// 跳過 Setup Assistant 的全部標記檔。回傳六個概念層、共七個 ``InjectedFile``
	/// （第六層 `.skipbuddy` 含兩個 User Template lproj 目錄各一）。
	///
	/// - Parameters:
	///   - user: 已離線建立的本機帳號 shortName，用來組 per-user 偏好路徑。
	///   - uid: 該帳號的 uid，作為 per-user 檔案的 owner。
	public static func layers(forUser user: String, uid: Int) throws -> [InjectedFile] {
		let didSee = try plistData(didSeePreferences())
		let managed = try plistData(skipPreferences())
		return [
			InjectedFile(
				relativePath: "private/var/db/.AppleSetupDone",
				contents: Data(),
				owner: (0, 0),
				mode: 0o600
			),
			InjectedFile(
				relativePath: "Library/Preferences/com.apple.SetupAssistant.plist",
				contents: didSee,
				owner: (0, 0),
				mode: 0o644
			),
			InjectedFile(
				relativePath: "Users/\(user)/Library/Preferences/com.apple.SetupAssistant.plist",
				contents: didSee,
				owner: (uid, 20),
				mode: 0o600
			),
			InjectedFile(
				relativePath: "Library/Preferences/com.apple.SetupAssistant.managed.plist",
				contents: managed,
				owner: (0, 0),
				mode: 0o644
			),
			InjectedFile(
				relativePath: "Library/Receipts/.SetupRegComplete",
				contents: Data(),
				owner: (0, 0),
				mode: 0o644
			),
			InjectedFile(
				relativePath: "System/Library/User Template/Non_localized.lproj/.skipbuddy",
				contents: Data(),
				owner: (0, 0),
				mode: 0o644
			),
			InjectedFile(
				relativePath: "System/Library/User Template/English.lproj/.skipbuddy",
				contents: Data(),
				owner: (0, 0),
				mode: 0o644
			)
		]
	}

	// MARK: Private

	/// 系統與 per-user 共用的 `DidSee*` 偏好（值皆 `true`，外加 GestureMovieSeen）。
	/// 做成 func 而非 stored static——`[String: Any]` 非 Sendable、不可當 global let。
	private static func didSeePreferences() -> [String: Any] {
		[
			"DidSeeCloudSetup": true,
			"DidSeeSiriSetup": true,
			"DidSeePrivacy": true,
			"DidSeeTrueTone": true,
			"DidSeeAppearanceSetup": true,
			"DidSeeActivationLock": true,
			"DidSeeScreenTime": true,
			"DidSeeTouchIDSetup": true,
			"DidSeeApplePaySetup": true,
			"DidSeeAccessibility": true,
			"GestureMovieSeen": "none"
		]
	}

	/// `com.apple.SetupAssistant.managed.plist` 的 `Skip*` 偏好（值皆 `true`）。
	private static func skipPreferences() -> [String: Any] {
		[
			"SkipCloudSetup": true,
			"SkipSiriSetup": true,
			"SkipPrivacySetup": true,
			"SkipTrueTone": true,
			"SkipAppearance": true,
			"SkipScreenTime": true,
			"SkipTouchID": true,
			"SkipApplePaySetup": true,
			"SkipiCloudStorageSetup": true,
			"SkipFirstLoginOptimization": true
		]
	}

	private static func plistData(_ dictionary: [String: Any]) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
	}
}
