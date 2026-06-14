// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "MachineKit",
	platforms: [
		.macOS(.v13),
	],
	products: [
		.library(name: "MachineKit", targets: ["MachineKit"]),
	],
	dependencies: [
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.target(
			name: "MachineKit",
			path: "Sources",
			linkerSettings: [
				.linkedFramework("Virtualization"),
			],
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
	]
)
