// swift-tools-version: 6.1
// Smoke test for the takeover brain: load the local VLM, hand it a real
// screenshot + a task, and check it emits a parseable JSON action with a
// coordinate. Proves the offline grounding path works before wiring trust in
// the in-app loop. Build with Xcode (MLX Metal shaders).
import PackageDescription

let package = Package(
    name: "TakeoverGroundingSmokeTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "TakeoverGroundingSmokeTest",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ]
)
