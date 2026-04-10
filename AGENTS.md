# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). When the user asks for it, Clicky can also generate a markdown transcript file with ASCII-friendly layout descriptions and expose a tiny cursor-adjacent status chip that advertises `control + option + c` for copying it. A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Markdown Export**: Claude-generated `.md` transcript saved to `~/Downloads/Clicky Transcripts`, with objective text extraction and optional ASCII diagram blocks
- **Workspace Inventory**: User-approved coding workspaces saved in `~/Library/Application Support/Flowee/workspaces.json`, editable from the menu bar panel, and used as the deterministic allowlist for agent delegation. Each workspace also remembers its last-used local agent runtime
- **Agent Delegation**: Flowee routes a request into `reply`, `draft`, or `delegate` using a cheap Anthropic Haiku classifier call over the captured transcript + screenshot context. Delegate requests pause for explicit workspace selection from the allowed inventory, then launch a local coding-agent runtime chosen from a deterministic registry of supported CLIs
- **Delegation Runtime Registry**: Flowee maintains a curated local registry of supported coding-agent CLIs and only presents installed runtimes it can resolve deterministically from known binary names and install paths (`codex`, `claude`, `opencode`)
- **Delegation Log Sidebar**: Delegated agent runs stream their live CLI output into a right-edge floating sidebar, tailed from log files in `~/Library/Application Support/Flowee/Delegation Logs`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`
App runtime config: `ClickyWorkerBaseURL`, `OnboardingVideoURL` in `leanring-buddy/Info.plist`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Markdown Transcript Card**: Markdown export requests reuse the same screenshot capture as the spoken response, but run through a separate Claude prompt optimized for objective, diagrammatic markdown. The result is saved to `~/Downloads/Clicky Transcripts` and surfaced through a tiny click-through status chip that follows the cursor, then waits for `control + option + c` to copy the markdown to the clipboard.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1530 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, markdown transcript generation, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, cursor visibility, and the current reply/draft/delegate routing state. It also uses a Haiku classifier for intent routing and coordinates runtime-aware delegation into supported local coding agents. |
| `ClickyActionRouting.swift` | ~20 | Typed action-intent models for the reply/draft/delegate router, plus the pending delegation request payload that the picker and launcher flows will consume. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1240 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, workspace inventory editor, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~190 | Minimal cursor-adjacent status chip for markdown transcript exports. Shows generating / ready / copied states and tells the user when `control + option + c` is available. |
| `DelegationAgentRuntimeRegistry.swift` | ~110 | Deterministic registry of supported local coding-agent CLIs. Detects installed runtimes like Codex, Claude Code, and OpenCode from known binary paths and publishes the installed set to the delegation flow. |
| `DelegationRepoPickerOverlay.swift` | ~420 | Interactive cursor-adjacent workspace and agent picker used when Flowee routes a request into agent delegation. Supports cursor following, arrow-key navigation, return to confirm, escape to cancel, and mouse selection. |
| `DelegationLogSidebar.swift` | ~470 | Right-edge floating log viewer for delegated agent runs. Streams appended CLI output into a cinematic monospace sidebar while the local coding agent works, then suggests raising a PR when the process exits. |
| `CodexExecLauncher.swift` | ~430 | Shared launcher service for Flowee's supported local coding-agent CLIs. Creates a fresh branch, launches the selected runtime in the chosen workspace, writes logs to disk, and returns branch + PR context for the delegation sidebar. |
| `WorkspaceInventoryStore.swift` | ~235 | Persistent allowlist for code workspaces Flowee may delegate into. Loads and saves `workspaces.json` in Application Support, validates repo-like folders, and remembers the last-used local agent runtime per workspace. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Build an installable launcher app for everyday use
./scripts/build-launcher.sh

# Or build and install directly into /Applications
./scripts/build-launcher.sh --install

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run ad hoc `xcodebuild` commands from the terminal for normal development** — that invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

If you need an installable standalone build, use `./scripts/build-launcher.sh` instead of inventing a separate terminal build flow.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

Set `ClickyWorkerBaseURL` in `leanring-buddy/Info.plist` to your deployed Worker URL. For local Worker development, temporarily point that value to `http://localhost:8787`.
Set `OnboardingVideoURL` in `leanring-buddy/Info.plist` to an HLS video URL when you want the onboarding video + timed demo to run. Leave it empty or remove the key to skip the video/demo and go straight to the onboarding voice prompt.

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

### Secret hygiene

- **Real API keys must never enter the repo.** Every external API call is routed through the Cloudflare Worker proxy (`worker/src/index.ts`) and the real keys live only in Wrangler secrets (and, for local Worker dev, in `worker/.dev.vars`, which is gitignored).
- Never add an Anthropic / OpenAI / ElevenLabs / AssemblyAI key to `Info.plist`, `project.pbxproj`, a Swift constant, or any other tracked file. A previous hardcoded key in `project.pbxproj` had to be rotated — do not repeat that mistake.
- A pre-commit hook at `.githooks/pre-commit` scans staged diffs for strings that match real credential formats and refuses to commit them. Contributors activate it once per clone with `git config core.hooksPath .githooks`. Do NOT bypass it with `--no-verify`.
- Per-user Xcode state (`xcuserdata/`) is gitignored. Do not re-add it.

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
