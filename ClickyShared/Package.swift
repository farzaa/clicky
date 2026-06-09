// swift-tools-version: 6.0
//
//  ClickyShared
//
//  Cross-platform engine code lifted (with light adaptation) from the MIT-licensed
//  open-source Clicky macOS app at https://github.com/farzaa/clicky.
//
//  This package contains the platform-agnostic AI pipeline:
//    • Claude vision + streaming chat client (Cloudflare Worker proxy)
//    • ElevenLabs TTS client (Cloudflare Worker proxy)
//    • AssemblyAI streaming transcription provider (Cloudflare Worker token proxy)
//    • Audio conversion helpers (PCM16 mono for AssemblyAI streaming)
//    • Worker URL configuration
//    • Pointing tag parser for Claude's [POINT:x,y:label] responses
//    • System prompt strings tuned for the iOS companion experience
//
//  Both iOS (Yapr) and macOS (Clicky) apps depend on this package, so the engine
//  stays in one place and bug fixes apply everywhere.
//

import PackageDescription

let package = Package(
    name: "ClickyShared",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClickyShared",
            targets: ["ClickyShared"]
        )
    ],
    targets: [
        .target(
            name: "ClickyShared",
            path: "Sources/ClickyShared"
        )
    ]
)
