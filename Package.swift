// swift-tools-version: 6.2
// EmbedSearch — local EmbeddingGemma 2 semantic launcher for macOS.
// Build with `arch -arm64` (the default shell may run under Rosetta) and use
// xcodebuild for anything that links MLX (SwiftPM CLI cannot compile Metal shaders).

import PackageDescription

let package = Package(
    name: "EmbedSearch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EmbedCore", targets: ["EmbedCore"]),
        .library(name: "EmbedMLX", targets: ["EmbedMLX"]),
        .library(name: "SearchCore", targets: ["SearchCore"]),
        .executable(name: "embedsearch-cli", targets: ["EmbedSearchCLI"]),
    ],
    dependencies: [
        // Pinned to the merge commit of PR #684 (EmbeddingGemma 2 support). Tag 3.32.3 predates it.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            revision: "028a828efa1801ca6d40dfdca82fa501059dbf1f",
            traits: []
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Model-agnostic embedding contract: prompts, vector math. No MLX dependency.
        .target(name: "EmbedCore"),

        // EmbeddingGemma 2 on MLX (Metal). Only App and CLI link this.
        .target(
            name: "EmbedMLX",
            dependencies: [
                "EmbedCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),

        // Items, sources, lexical matching, vector index, hybrid ranking, persistence.
        .target(
            name: "SearchCore",
            dependencies: [
                "EmbedCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .executableTarget(
            name: "EmbedSearchCLI",
            dependencies: [
                "EmbedCore",
                "EmbedMLX",
                "SearchCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Model-free benchmark + golden-output snapshot of the search pipeline (`swift run -c release SearchBench`).
        .executableTarget(name: "SearchBench", dependencies: ["SearchCore", "EmbedCore"]),

        .testTarget(name: "EmbedCoreTests", dependencies: ["EmbedCore"]),
        .testTarget(
            name: "SearchCoreTests",
            dependencies: ["SearchCore", "EmbedCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
