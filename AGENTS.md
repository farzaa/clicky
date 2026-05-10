# Dot - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap, gated by macOS Listen Event/Input Monitoring permission.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Computer Control**: Claude can emit hidden `[CLICK:x,y:label:screenN]`, `[TYPE:text]`, and `[MEDIA:play_pause|next|previous]` tags when the user asks it to operate the computer. `CompanionComputerController` posts local CGEvents for click/type actions and system-defined media-key events for playback controls. Obvious media-only phrases such as "pause the music" execute locally before the screenshot/model path.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `DotAnalytics.swift`

### Backend (vibe-id)

The app never calls external APIs directly. One Cloudflare Worker sits in front:

**`vibe-id`** (`api.accounts.vibe-research.net`) — central service shared across all Vibe Research projects. Owns Google OAuth, users, install tokens, per-project per-day quotas, admin endpoints, D1 state, AND the upstream API keys (Anthropic, ElevenLabs, AssemblyAI). Inference endpoints are public, bearer-authed; the install token is project-scoped at mint time so vibe-id derives the project from the token alone.

Source lives in a separate repo (`~/Desktop/projects/vibe-id/`, `github.com/Clamepending/vibe-id`); this repo only consumes its API.

**Routes the macOS app uses:**

| Route | Auth | Purpose |
|-------|------|---------|
| `GET /health` | none | Liveness check |
| `GET /auth/start?project=dot&device_id=…` | none | Begin Google sign-in |
| `POST /auth/exchange` | none | Trade one-time code for install token |
| `GET /auth/me` | bearer | Current user + per-project usage today |
| `POST /auth/signout` | bearer | Revoke the calling install token |
| `POST /chat` | bearer + quota | Anthropic Messages (streaming SSE) |
| `POST /tts` | bearer + quota | ElevenLabs TTS — quota charged in characters |
| `POST /transcribe-token` | bearer + quota | AssemblyAI temp token — quota charged per session |

There is no per-project worker. The macOS app's `DotProxyBaseURL` and `VibeIdBaseURL` both point at `https://api.accounts.vibe-research.net`. Adding a new project (Swarmlab next) is one INSERT into vibe-id's `projects` table and a `project=…` parameter from that project's client.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Dot" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Sign-in handoff via `dot://`**: The macOS app cannot complete an OAuth flow inside its own UI without bouncing through the system browser. `DotAccountManager.signIn()` opens `<vibe-id>/auth/start?project=dot&device_id=<uuid>` in the user's browser; vibe-id bounces through Google and lands on `dot://auth?code=…`, which macOS routes back to the app via the `CFBundleURLTypes` entry in `Info.plist`. The AppDelegate's `application(_:open:)` forwards that URL to the account manager, which trades the code for an install token via vibe-id `/auth/exchange`. The token is stored in the macOS Keychain (`DotInstallTokenStore`) and never written to disk anywhere else.

**Multi-turn agent loop**: After the user releases push-to-talk, `CompanionManager.sendTranscriptToClaudeWithScreenshot` runs an agent loop of up to `maxAgentStepsPerUserTurn` (10) steps. Each step captures the current screen, sends it to Claude with the conversation history + this-turn step history, parses any `[CLICK]` / `[TYPE]` / `[KEY]` / `[MEDIA]` action tags, executes them, and re-captures for the next step. The loop ends when Claude returns a response with no action tags (task complete), the step budget is exhausted, the user moves the hardware mouse > 40pt (treated as the user reclaiming control), or the task is cancelled by another push-to-talk. Spoken text from every step is concatenated and TTS'd once at the end. A 500ms settling delay between steps lets animations and page loads land before the next screen capture.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1640 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, overlay management, hidden Claude control-tag parsing, direct media-command recognition, stuck-state recovery, permission state, and development diagnostics. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → optional local media control → screenshot → Claude → TTS → pointing/click/type/media pipeline. |
| `CompanionComputerController.swift` | ~280 | Local computer-control helper. Converts AppKit screen coordinates to Quartz event coordinates, tries `AXPress` at the blue-cursor target, falls back to coordinate CGEvents while restoring the hardware cursor, types text, and posts global media-key events. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~815 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~1050 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~540 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~199 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap, logs raw shortcut events for development diagnostics, and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `DotAnalytics.swift` | ~125 | PostHog analytics integration. Tracks counts/durations only — never raw transcript or response text. |
| `DotDebugLogger.swift` | ~116 | Local file-backed development logger. Writes rotated diagnostic logs to `~/Library/Logs/Dot/dot.log` and mirrors concise lines to stdout. |
| `DotAccountManager.swift` | ~200 | Google sign-in flow + signed-in user state. Opens `<vibe-id>/auth/start?project=dot` in the system browser, handles the `dot://auth?code=…` callback, exchanges the code for an install token, fetches `/auth/me` for usage, and exposes `signIn()` / `signOut()` for the panel. Talks to vibe-id directly. |
| `DotInstallTokenStore.swift` | ~140 | Thread-safe Keychain wrapper for the long-lived install token. Uses the legacy file-based keychain (data-protection keychain needs entitlements we don't ship) plus an in-memory cache so non-MainActor API clients don't pay a SecItem syscall on every request. |
| `WindowPositionManager.swift` | ~320 | Window placement logic, Screen Recording permission flow, Accessibility and Input Monitoring permission helpers, and last-known permission grant caching for local rebuilds. |
| `AppBundleConfiguration.swift` | ~45 | Runtime configuration reader for keys stored in the app bundle Info.plist, including `DotProxyBaseURL` and `VibeIdBaseURL`. |
| `website/dot/index.html` + `account.html` + `admin.html` | — | Static pages deployed to `dot.vibe-research.net`: landing/download, per-user usage dashboard, admin dashboard. All call vibe-id directly for auth + inference + admin. |
| `website/research-lab/index.html` | — | Minimal landing page deployed to `vibe-research.net` root with links to `swarmlab.vibe-research.net` and `dot.vibe-research.net`. |
| `vibe-id-project-template/` | — | Drop-in starter for any new vibe-id-powered product. Holds the 75-line forwarder, a project-agnostic Swift SDK (`VibeIdAccount` + `VibeIdInstallTokenStore`), a JS SDK (`vibeid.js`), a cross-project account page, and a README. Copy + change `PROJECT_ID` + deploy = new project online. |
| `VIBE_ID_HANDOFF.md` | — | Schema + handler changes that need to land in the vibe-id repo for the multi-project story (per-project URL schemes, per-project upstream routing in a `project_endpoints` table). Apply once; future projects then bootstrap from the template with no vibe-id-side changes. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Local install without Xcode, useful on machines with command line tools only.
# Uses the first Developer ID Application identity if available, otherwise
# falls back to ad-hoc signing.
./scripts/install-local-dev-app.sh

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc. Prefer Xcode Cmd+R or `scripts/install-local-dev-app.sh`.

## Backend

There is no per-project worker in this repo. All API calls go to `vibe-id` (`api.accounts.vibe-research.net`). To work on the backend, clone `github.com/Clamepending/vibe-id` and follow its README.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
