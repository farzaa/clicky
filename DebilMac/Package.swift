// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DebilMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DebilMac", targets: ["DebilMac"]),
    ],
    targets: [
        .executableTarget(
            name: "DebilMac",
            path: "Sources"
        ),
    ]
)
