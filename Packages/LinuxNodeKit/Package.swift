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
		.package(path: "../NymphKit"),
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
				.product(name: "NymphKit", package: "NymphKit"),
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
			dependencies: [
				"LinuxNodeKit",
				// 測試自己 import 這兩個（假介面用 `CIDRv4`／`Interface`），不靠受測 target
				// 的傳遞 import——後者若改掉依賴，測試會以「找不到模組」的形式壞掉。
				.product(name: "Containerization", package: "containerization"),
				.product(name: "ContainerizationExtras", package: "containerization"),
			],
			path: "Tests/LinuxNodeKitTests"
		),
	]
)
