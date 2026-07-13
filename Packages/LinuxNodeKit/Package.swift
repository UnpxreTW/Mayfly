// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "LinuxNodeKit",
	platforms: [
		.macOS("15.0"),
	],
	products: [
		.library(name: "LinuxNodeKit", targets: ["LinuxNodeKit"]),
	],
	dependencies: [
		.package(path: "../mayfly-cli"),
		.package(path: "../MachineKit"),
		.package(url: "https://github.com/apple/containerization.git", from: "0.37.0"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.target(
			name: "LinuxNodeKit",
			dependencies: [
				.product(name: "NymphKit", package: "mayfly-cli"),
				.product(name: "MachineKit", package: "MachineKit"),
				.product(name: "Containerization", package: "containerization"),
				.product(name: "ContainerizationOS", package: "containerization"),
			],
			path: "Sources/LinuxNodeKit",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.testTarget(
			name: "LinuxNodeKitTests",
			dependencies: ["LinuxNodeKit"],
			path: "Tests/LinuxNodeKitTests"
		),
	]
)
