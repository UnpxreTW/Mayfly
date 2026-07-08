// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "mayfly-cli",
	platforms: [
		.macOS(.v13),
	],
	products: [
		.executable(name: "mayfly", targets: ["mayfly"]),
	],
	dependencies: [
		.package(path: "../MachineKit"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.executableTarget(
			name: "mayfly",
			dependencies: [
				.product(name: "MachineKit", package: "MachineKit"),
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			path: "Sources",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
	]
)
