// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "MayflyUI",
	platforms: [
		// GUI 下限刻意高於引擎（MachineKit / mayfly-cli 為 macOS 13）：外殼是非底層工具、
		// 貼近新系統換取無相容分支的實作；引擎與 CLI 的觸及面不受此影響。
		.macOS("15.0"),
	],
	products: [
		.library(name: "MayflyUI", targets: ["MayflyUI"]),
	],
	dependencies: [
		.package(path: "../mayfly-cli"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.target(
			name: "MayflyUI",
			dependencies: [
				.product(name: "NymphKit", package: "mayfly-cli"),
			],
			path: "Sources/MayflyUI",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.testTarget(
			name: "MayflyUITests",
			dependencies: ["MayflyUI"],
			path: "Tests/MayflyUITests"
		),
	]
)
