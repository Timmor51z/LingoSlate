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
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            from: "1.3.0"
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
            dependencies: [
                "ClassBridgeCore",
                "ClassBridgeAudio",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
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
