// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClickyCheck",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Clicky", targets: ["ClickyCheck"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0"),
        .package(url: "https://github.com/PostHog/posthog-ios", exact: "3.47.0")
    ],
    targets: [
        .executableTarget(
            name: "ClickyCheck",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "leanring-buddy",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "leanring-buddy.entitlements",
                "AGENTS.md"
            ],
            resources: [
                .copy("ff.mp3"),
                .copy("eshop.mp3"),
                .copy("enter.mp3"),
                .copy("steve.jpg"),
                .copy("codex-add-project.png")
            ],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ],
    swiftLanguageVersions: [.v5]
)
