# AGENTS.md - leanring-buddy

This directory contains the native macOS app target. Start with the root `AGENTS.md` for the full architecture, build constraints, and coding conventions; this file only adds target-specific guidance for edits under `leanring-buddy/`.

## Target Shape

- `leanring_buddyApp.swift` is the menu-bar app entry point and wires `CompanionAppDelegate`, `MenuBarPanelManager`, and `CompanionManager` together.
- `CompanionManager.swift` owns the core interaction state machine: push-to-talk, screenshot capture, Claude streaming, TTS playback, cursor visibility, and pointing coordination.
- `CompanionPanelView.swift`, `CompanionResponseOverlay.swift`, `OverlayWindow.swift`, and `DesignSystem.swift` own the visible SwiftUI/AppKit UI surfaces.
- `BuddyDictationManager.swift` plus the `*TranscriptionProvider.swift` files own microphone capture and transcription-provider behavior.
- `ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElevenLabsTTSClient.swift`, and `AssemblyAIStreamingTranscriptionProvider.swift` talk to the Worker proxy, not directly to third-party APIs.
- `AppBundleConfiguration.swift` is the runtime reader for app-bundle configuration values stored in `Info.plist`.

## Editing Rules

- Keep changes local to the file that owns the behavior. Do not route new app state through `CompanionManager` unless it needs to coordinate the main interaction pipeline.
- Preserve the menu-bar-only app model. Do not introduce a dock window, document scene, or ordinary app lifecycle unless the root architecture changes first.
- Keep all UI mutations on the main actor. Prefer explicit `@MainActor` isolation over detached main-thread hops.
- Use the existing `DS` design tokens for panel and overlay UI. Do not add one-off colors, spacing scales, or button styles.
- Do not put API keys, bearer tokens, or provider secrets in Swift source, `Info.plist`, or project build settings. Secrets belong in the Worker environment.
- Do not run `xcodebuild` from the terminal. Open the Xcode project and build there so macOS permissions do not get reset.
