// swift-tools-version: 6.0
//
// VMKit — Mayfly VZ engine library.
//
// This package is intentionally a *plain SPM library*. It is NOT pulled into
// the Tuist graph (only the SwiftUI macOS App target is Tuist-generated). The
// CLI/MCP executables that drive this engine are separate plain-SPM executable
// packages, so that Tuist 4's from-source-executable normalize bug (which can
// overwrite an executable's SwiftFileList with a sibling library's list and
// drop main.swift out of the inputs) is never triggered.
//
// Built/verified with Swift 6.3.2, macOS 26.5 SDK, Apple Silicon (arm64).

import PackageDescription

let package = Package(
    name: "VMKit",
    platforms: [
        // VZEFIBootLoader + VZGenericPlatformConfiguration require macOS 13.
        // We pin the deployment target to 13 so the engine itself stays usable
        // from older hosts; runtime-version-gated APIs are annotated inline.
        .macOS(.v13)
    ],
    products: [
        .library(name: "VMKit", targets: ["VMKit"])
    ],
    targets: [
        .target(
            name: "VMKit",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
