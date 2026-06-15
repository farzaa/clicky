// swift-tools-version: 6.1
// A runnable window app that demonstrates Clicky's Local Mode feature without
// needing mic / accessibility / screen-recording grants: type a question, the
// on-device model answers (streamed text + latency badge), and it speaks the
// reply via AVSpeechSynthesizer — the same model, params, and offline TTS the
// real app uses in Local Mode. Build with Xcode (MLX Metal shaders).
import PackageDescription

let package = Package(
    name: "ClickyLocalDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClickyLocalDemo",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ]
)
