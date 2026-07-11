// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClassBridge",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "ClassBridgeCore", targets: ["ClassBridgeCore"]),
        .executable(name: "ClassBridgeMac", targets: ["ClassBridgeMac"]),
    ],
    targets: [
        .target(name: "ClassBridgeCore"),
        .executableTarget(
            name: "ClassBridgeMac",
            dependencies: ["ClassBridgeCore"]
        ),
        .testTarget(
            name: "ClassBridgeCoreTests",
            dependencies: ["ClassBridgeCore"]
        ),
    ]
)
