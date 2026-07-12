// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LingoSlate",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LingoSlateCore", targets: ["LingoSlateCore"]),
        .library(name: "LingoSlateAudio", targets: ["LingoSlateAudio"]),
        .library(name: "LingoSlateTranslation", targets: ["LingoSlateTranslation"]),
        .executable(name: "LingoSlateMac", targets: ["LingoSlateMac"]),
        .executable(name: "LingoSlateASRSmoke", targets: ["LingoSlateASRSmoke"]),
        .executable(name: "LingoSlateBenchmark", targets: ["LingoSlateBenchmark"]),
        .executable(
            name: "LingoSlateTranscriptBenchmark",
            targets: ["LingoSlateTranscriptBenchmark"]
        ),
        .executable(
            name: "LingoSlateTranslationBenchmark",
            targets: ["LingoSlateTranslationBenchmark"]
        ),
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
        .target(name: "LingoSlateCore"),
        .target(
            name: "LingoSlateAudio",
            dependencies: [
                "LingoSlateCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "LingoSlateTranslation",
            dependencies: [
                "LingoSlateCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "LingoSlateMac",
            dependencies: [
                "LingoSlateCore",
                "LingoSlateAudio",
                "LingoSlateTranslation",
            ]
        ),
        .executableTarget(
            name: "LingoSlateASRSmoke",
            dependencies: [
                "LingoSlateCore",
                "LingoSlateAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "LingoSlateBenchmark",
            dependencies: [
                "LingoSlateCore",
                "LingoSlateAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "LingoSlateTranscriptBenchmark",
            dependencies: ["LingoSlateCore"]
        ),
        .executableTarget(
            name: "LingoSlateTranslationBenchmark",
            dependencies: [
                "LingoSlateCore",
                "LingoSlateTranslation",
            ]
        ),
        .testTarget(
            name: "LingoSlateCoreTests",
            dependencies: ["LingoSlateCore", "LingoSlateAudio"]
        ),
        .testTarget(
            name: "LingoSlateMacTests",
            dependencies: [
                "LingoSlateMac",
                "LingoSlateCore",
                "LingoSlateTranslation",
            ]
        ),
    ]
)
