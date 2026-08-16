// swift-tools-version: 6.0

import PackageDescription

let package: Package = .init(
	name: "NymphKit",
	platforms: [
		.macOS("26.0"),
	],
	products: [
		.library(name: "NymphKit", targets: ["NymphKit"]),
	],
	dependencies: [
		.package(path: "../MachineKit"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.target(
			name: "NymphKit",
			dependencies: [
				.product(name: "MachineKit", package: "MachineKit"),
			],
			path: "Sources/NymphKit",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.testTarget(
			name: "NymphKitTests",
			dependencies: ["NymphKit"],
			path: "Tests/NymphKitTests"
		),
	]
)
