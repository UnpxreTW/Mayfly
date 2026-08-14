// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "MayflyUI",
	platforms: [
		.macOS("26.0"),
	],
	products: [
		.library(name: "MayflyUI", targets: ["MayflyUI"]),
	],
	dependencies: [
		.package(path: "../NymphKit"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.target(
			name: "MayflyUI",
			dependencies: [
				.product(name: "NymphKit", package: "NymphKit"),
			],
			path: "Sources/MayflyUI",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
		.testTarget(
			name: "MayflyUITests",
			dependencies: ["MayflyUI"],
			path: "Tests/MayflyUITests",
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
	]
)
