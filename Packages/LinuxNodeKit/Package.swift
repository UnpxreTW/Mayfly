// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "LinuxNodeKit",
	platforms: [
		.macOS("26.0"),
	],
	products: [
		.library(name: "LinuxNodeKit", targets: ["LinuxNodeKit"]),
	],
	dependencies: [
		.package(path: "../mayfly-cli"),
		.package(path: "../MachineKit"),
		// vminitd（initfs image）tag 必須與套件版本一致——range 解析飄版會造成 host 端
		// API 與 guest 內 vminitd 版本 skew。exact pin（非 from:）：升級走人工復驗；
		// 版本正本＝LinuxToolchain.containerizationVersion，測試驗 Package.resolved 對齊。
		.package(url: "https://github.com/apple/containerization.git", exact: "0.37.0"),
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
