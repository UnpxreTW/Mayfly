//
//  Mayfly
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ProjectDescription

// app bundle 需要真正的 `.app`（簽 `com.apple.security.virtualization` 的最小單位），
// SwiftPM executable target 產不出來——故 app 外殼走 Tuist，其餘一律留在 SwiftPM。
//
// 圖的形狀刻意如此：**只有 app target 進 Tuist**。CLI（`Packages/mayfly-cli` 的 `mayfly`
// executable）維持純 SwiftPM、不進本圖——Tuist 4 對「同一 package 內 executable ＋
// library 並存」會以 library 的 SwiftFileList 覆寫 executable 的原始碼清單、導致
// `main` 進入點缺失。app 只引用 library 產物（`MayflyUI`），繞開該路徑。

let project = Project(
	name: "Mayfly",
	organizationName: "Unpxre",
	packages: [
		.local(path: "Packages/MayflyUI"),
	],
	settings: .settings(
		base: [
			"SWIFT_VERSION": "6.0",
		],
		defaultSettings: .recommended
	),
	targets: [
		.target(
			name: "Mayfly",
			destinations: .macOS,
			product: .app,
			bundleId: "me.unpxre.Mayfly",
			// 外殼下限＝macOS 15（非底層工具貼近新系統；引擎與 CLI 各自維持較低下限）。
			deploymentTargets: .macOS("15.0"),
			infoPlist: .extendingDefault(with: [
				"CFBundleName": "Mayfly",
				"CFBundleShortVersionString": "0.0.1",
				"CFBundleVersion": "1",
				"NSHumanReadableCopyright": "Copyright © 2026 Unpxre. Licensed under the Apache License 2.0.",
			]),
			sources: ["Sources/**"],
			entitlements: "Mayfly.entitlements",
			dependencies: [
				.package(product: "MayflyUI"),
			],
			settings: .settings(
				base: [
					// ad-hoc 簽：本階段不分發，不需 Developer ID 與 notarize；帶
					// entitlement 的 ad-hoc 簽已足以讓 app 取得 virtualization 能力。
					"CODE_SIGN_IDENTITY": "-",
					"CODE_SIGN_STYLE": "Manual",
					"CODE_SIGNING_REQUIRED": "YES",
					"DEVELOPMENT_TEAM": "",
				]
			)
		),
	]
)
