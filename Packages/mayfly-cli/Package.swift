// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "mayfly-cli",
	platforms: [
		.macOS("26.0"),
	],
	products: [
		.executable(name: "mayfly", targets: ["mayfly"]),
		.library(name: "NymphMCPShim", targets: ["NymphMCPShim"]),
	],
	dependencies: [
		.package(path: "../MachineKit"),
		.package(path: "../NymphKit"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
		// pre-1.0（0.12.1）——風險關在 NymphMCPShim 這個薄 shim，daemon 核心協議走自訂
		// NymphProtocol，不依賴此 SDK。exact pin（非 from:）：API 未凍結、升級走人工復驗。
		.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
	],
	targets: [
		.target(
			name: "NymphMCPShim",
			dependencies: [
				.product(name: "NymphKit", package: "NymphKit"),
				.product(name: "MCP", package: "swift-sdk"),
			],
			path: "Sources/NymphMCPShim",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.executableTarget(
			name: "mayfly",
			dependencies: [
				.product(name: "MachineKit", package: "MachineKit"),
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.product(name: "NymphKit", package: "NymphKit"),
				"NymphMCPShim",
			],
			path: "Sources/mayfly",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.testTarget(
			name: "NymphMCPShimTests",
			dependencies: [
				"NymphMCPShim",
				.product(name: "NymphKit", package: "NymphKit"),
				.product(name: "MCP", package: "swift-sdk"),
			],
			path: "Tests/NymphMCPShimTests"
		),
	]
)
