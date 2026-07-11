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
        .library(name: "ClassBridgeAudio", targets: ["ClassBridgeAudio"]),
        .executable(name: "ClassBridgeMac", targets: ["ClassBridgeMac"]),
        .executable(name: "LecCueASRSmoke", targets: ["LecCueASRSmoke"]),
        .executable(name: "LecCueBenchmark", targets: ["LecCueBenchmark"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
    ],
    targets: [
        .target(name: "ClassBridgeCore"),
        .target(
            name: "ClassBridgeAudio",
            dependencies: [
                "ClassBridgeCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "ClassBridgeMac",
            dependencies: ["ClassBridgeCore", "ClassBridgeAudio"]
        ),
        .executableTarget(
            name: "LecCueASRSmoke",
            dependencies: [
                "ClassBridgeCore",
                "ClassBridgeAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "LecCueBenchmark",
            dependencies: [
                "ClassBridgeCore",
                "ClassBridgeAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "ClassBridgeCoreTests",
            dependencies: ["ClassBridgeCore", "ClassBridgeAudio"]
        ),
        .testTarget(
            name: "ClassBridgeMacTests",
            dependencies: ["ClassBridgeMac", "ClassBridgeCore"]
        ),
    ]
)
