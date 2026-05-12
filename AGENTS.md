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
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap, gated by macOS Listen Event/Input Monitoring permission.
- **Agent Loop**: Multi-step tool-use loop via Anthropic's Messages API `tools` parameter (non-streaming). Each turn returns text content blocks (TTS narration) and tool_use blocks; the controller executes each tool, captures a fresh screen, and sends tool_results + image back as the next user message. Loop terminates on a turn with no tool_use (task complete), `bail_out` tool, hardware mouse movement, or step budget exhausted. System prompt + tool schemas cached via Anthropic prompt caching. See `docs/agent-loop-tool-use-migration.md` for the design.
- **Computer Control Tools**: `click_element`, `type_text`, `fill_text_field`, `press_keystroke`, `navigate_browser`, `open_new_tab`, `close_tab`, `switch_tab`, `browser_back`, `browser_forward`, `media_control`, `point_at_element`, `bail_out`. Schemas in `AgentToolDefinitions.swift`. `CompanionComputerController` posts local CGEvents for click/type/keystroke and system-defined media-key events. Obvious media-only phrases such as "pause the music" execute locally before the screenshot/model path. Synthetic clicks send `mouseMoved → 25 ms → mouseDown → 40 ms → mouseUp → 40 ms → warp` so Electron apps (Slack/Discord/VS Code) actually transfer focus to the element underneath — naive 0-duration down+up doesn't.
- **Composite Tools** (key architectural pattern): `fill_text_field(x, y, text, clear_existing?)` atomically does click → 150 ms focus settle → optional cmd+a → type, in one tool invocation. Exists because fragmenting "click + type" across separate tool turns invites the screenshot-feedback doubt loop — model sees the click in history, can't visually confirm focus landed (Electron contenteditables don't render carets in captured frames, AX is opaque to the renderer process), and re-clicks. Composite tools collapse the action so the model can't second-guess intermediate state it can't observe. Pattern is reusable: any time the agent loop has to coordinate two actions across an unobservable state change, promote it to one tool. Future candidates: `navigate_and_click`, `select_and_replace`, `focus_and_press`.
- **Element Pointing**: `point_at_element` tool call sets a target screen coordinate; the overlay maps it to the correct monitor and animates the blue cursor along a bezier arc. The onboarding demo flow uses a simpler `[POINT:x,y:label]` text tag (separate code path from the agent loop).
- **Long-Term Memory**: Anthropic's predefined memory tool (`memory_20250818`) is exposed in the agent loop alongside the computer-control tools. The model issues view/create/str_replace/insert/delete/rename commands scoped to a virtual `/memories` root; `DotMemoryStore.swift` maps each to a real file under `~/Library/Application Support/Dot/memories/`. Files persist across app restarts. The `anthropic-beta: context-management-2025-06-27` header is set on tool-use requests in `ClaudeAPI.swift` and must be forwarded by the vibe-id proxy.
- **Cross-Turn Conversation Thread**: `conversationHistory` in `CompanionManager` is a running array of `ConversationExchange` (user transcript + dot response + timestamp) carried across every push-to-talk turn. Persisted to `~/Library/Application Support/Dot/conversation_history.json` after every turn (`DotConversationHistoryStore`) and reloaded on app launch so the thread survives restarts. Compaction triggers on EITHER an entry-count threshold (50) or a token-count threshold (~10k tokens, char/4 estimate) — token-based is the primary trigger; entry-count is defense in depth. The oldest entries are summarized into a single `[earlier conversation summary]` entry via a Haiku 4.5 background call (`ClaudeAPI.summarizeConversationViaHaiku`), keeping the most recent 20 verbatim. Compaction is fire-and-forget so it never blocks TTS, and is race-safe with concurrent appends.
- **Memory Inspector Panel** (`MemoryInspectorView`): collapsible section in the menu bar panel that shows every entry under `/memories/` plus the conversation-thread length. Per-row "Forget" buttons, a "Forget conversation thread" button, and a "Forget everything" button (with confirmation dialog) make memory user-auditable and user-correctable. Pinned entries are flagged with a pin glyph. Trust foundation against silent learning — without this, every confabulation or prompt-injected memory is invisible.
- **Memory-Write Toasts** (Phase 3b trust surface): every `memory.create` / `memory.str_replace` / `memory.delete` / `memory.rename` issued by the model surfaces as a dismissible toast in the panel via `CompanionManager.recordMemoryWriteToast`. Toasts stack up to 5 and persist across panel open/close until the user dismisses or undoes them. Undo deletes the underlying memory file. Defends against prompt-injection-via-screenshot — even if a screenshot tricks the model into a memory write, the toast surfaces it for review.
- **Pinned vs Auto-Extracted Memory** (Phase 3c): `/memories/pinned/` is a reserved subdirectory for user-asserted ("remember this forever") facts. The system prompt routes explicit user-stated facts there; model-inferred facts go under `/memories/` root. Sleep-cycle hygiene pass skips `/memories/pinned/` entirely. The inspector panel shows pinned entries with a pin glyph.
- **Sleep-Cycle Consolidation** (Phase 4): a long-running `Task` started in `CompanionManager.start()` polls every 5 minutes and runs a consolidation pass when (a) the user has been continuously idle ≥30 min (via `DotIdleDetector` over `CGEventSource`), (b) ≥24h has passed since the last pass, and (c) ≥5 turns have happened since then. Consolidation: (i) proactively compacts the conversation thread even if not at overflow (coordinated with the regular compaction task slot to avoid races), (ii) runs a READ-ONLY Haiku 4.5 review of `/memories/` (excluding `/pinned/`) via `ClaudeAPI.reviewMemoryStateViaHaiku` and surfaces the observation summary as a panel toast next time the user opens Dot. Never auto-mutates memory — surfaces for human review only.
- **Background Agent Tasks**: Explicit `dot agent ...` requests are handed off to the user's locally-installed Claude Code CLI. Dot is the orchestrator — voice trigger, working-dir setup, panel UI, lifecycle, cancel, and delete. The actual coding work happens in a subprocess. Tasks live in `~/Desktop/Dot Tasks/<slug>-<date>/` with auto-`git init`. The right-edge dot overlay surfaces one colored dot per running/recent task; clicking a dot opens live events streamed from Claude Code's `stream-json` output. Normal non-prefixed requests never auto-spawn a background agent. Short cancellation phrases ("cancel that") kill the most recent running task. See `docs/agent-tasks-design.md` and the `AgentTaskOrchestration/` directory.
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

**Multi-turn agent loop**: After the user releases push-to-talk, `CompanionManager.sendTranscriptToClaudeWithScreenshot` runs a multi-step tool-use loop of up to `maxAgentStepsPerUserTurn` (40) steps. The loop sends the screenshot + transcript + tool schemas to Claude; the response is a list of text content blocks (TTS narration) and tool_use blocks (structured action calls). The controller executes each tool_use (clicks/keystrokes/navigation/etc.), captures the post-action screen, and sends `tool_result` blocks + the new image back as the next user message — Anthropic-native multi-turn. The loop ends when Claude returns a turn with no tool_use blocks (task complete), the `bail_out` tool is invoked, the user moves the hardware mouse > 40pt during the inter-step settling window (treated as the user reclaiming control — the baseline is re-captured after every step's actions), the step budget is exhausted, or push-to-talk re-fires. Per-step text is enqueued onto a serial TTS playback queue so the user hears narration in real time as actions execute. A 500ms settling delay between steps lets animations and page loads land; `navigate_browser` and `open_new_tab` add an extra 1.5s post-return wait specifically for page loads. System prompt + tool schemas are marked cacheable via `cache_control: ephemeral` so the static prefix amortizes across steps within a turn.

**Background agent dispatch**: Background coding agents are explicit only. Every finalized transcript that the direct-media short-circuit declines goes to the normal live inline tool-use loop unless it starts with `dot agent ...`. The prefix is parsed deterministically in `CompanionManager`; no LLM route classifier decides whether to spawn a worker. Prefixed requests become an `AgentTaskBrief`, get a working dir under `~/Desktop/Dot Tasks/`, an `INSTRUCTIONS.md` written from the stripped request, and a fresh `git init`. Existing absolute or `~/...` paths in the stripped request are passed to Claude Code with `--add-dir` so explicit project-folder work can inspect real files. `AgentTaskManager` can run up to 5 concurrent coding agents; each task owns its own `ClaudeCodeAdapter`, event-consumer task, and wall-clock watchdog. Short cancellation phrases cancel the most recently started running task. Other non-prefixed transcripts stay inline rather than becoming implicit background-agent follow-ups. The transparent right-edge subagent dot overlay shows one colored dot per running/recent task; clicking a dot opens `AgentTaskPanelView` for that task's output. Hovering a dot reveals an `x` that deletes the subagent from Dot; deleting a running subagent cancels its worker but leaves the working directory on disk. Authentication is the user's responsibility — they must have run `claude` locally at least once to sign in or set `ANTHROPIC_API_KEY`.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~150 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager`, `AgentTaskPanelManager`, `SubagentDotOverlayManager`, and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~3480 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude tool-use agent loop, ElevenLabs TTS (per-step narration queue), overlay management, direct media-command short-circuit, stuck-state recovery, permission state, and development diagnostics. Holds the `AgentTaskManager` instance and wires its announcement handler into TTS. Routes finalized transcripts to the live inline loop unless they start with explicit `dot agent ...`, which spawns a background coding agent. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. |
| `AgentTaskOrchestration/AgentTaskBrief.swift` | ~120 | Core value types for the background-task pipeline: `AgentTaskBrief` (explicit command brief), `AgentTaskEvent` (worker progress), `AgentTaskStatus` (lifecycle), `AgentTask` (ObservableObject holding brief + events + status), `TimestampedAgentTaskEvent`. |
| `AgentTaskOrchestration/AgentWorker.swift` | ~50 | Protocol abstracting "an installed coding agent that can execute a background task." Defines `isInstalledOnSystem()`, `spawn(brief:)` returning an `AsyncThrowingStream<AgentTaskEvent, Error>`, `sendFollowUpMessage(_:)`, and `cancel()`. v1 has one conformer (Claude Code); designed so adding Codex or a local Swift loop is a single new file. |
| `AgentTaskOrchestration/ClaudeCodeAdapter.swift` | ~660 | `AgentWorker` conformer for Anthropic's `claude` CLI. Resolves the binary from common npm/Homebrew/Volta install paths (GUI apps don't inherit the interactive shell's PATH). Spawns `claude -p --input-format=stream-json --output-format=stream-json --permission-mode=acceptEdits --max-turns N` with a working directory, plus `--add-dir` for explicit user-supplied paths detected in `dot agent` requests. Parses each stdout JSON line into typed `AgentTaskEvent`s. Forwards mid-run follow-ups by writing JSON user-message lines to stdin. Cancels via SIGTERM with a SIGKILL escalation after 2s. |
| `AgentTaskOrchestration/AgentTaskManager.swift` | ~400 | Multi-task lifecycle manager (`@MainActor`, `ObservableObject`). Validates worker installation, creates each working dir under `~/Desktop/Dot Tasks/<slug>-<date>/`, spawns one `ClaudeCodeAdapter` per coding agent, consumes per-task event streams, updates `runningTasks` + `recentlyFinishedTasks`, enforces per-task wall-clock watchdogs, caps concurrency at 5, supports deleting/cancelling subagents from UI state without deleting working dirs, and fires `AgentTaskAnnouncement`s back to its host (CompanionManager) for TTS. |
| `AgentTaskOrchestration/AgentTaskPanelManager.swift` | ~125 | Owns the right-edge floating `NSPanel` hosting `AgentTaskPanelView`. Same nonactivating-floating-canJoinAllSpaces pattern as `MenuBarPanelManager`. Shows the panel for a selected task when `SubagentDotOverlayManager` calls `showPanel(for:)`. |
| `AgentTaskOrchestration/AgentTaskPanelView.swift` | ~410 | Minimal SwiftUI panel content for one selected coding-agent task: header with close button, status badge, title, latest assistant summary, collapsed-by-default event history, and cancel for running tasks. Destructive deletion stays on the hover `x` in the dot overlay. Uses `DS` design system tokens. |
| `AgentTaskOrchestration/SubagentDotOverlayManager.swift` | ~150 | Owns the transparent right-edge subagent dot `NSPanel`. Observes `AgentTaskManager.runningTasks` and `recentlyFinishedTasks`, positions the dot stack on the active screen, and opens the selected task detail panel when a dot is clicked. |
| `AgentTaskOrchestration/SubagentDotOverlayView.swift` | ~165 | SwiftUI vertical stack of colored subagent dots. Running tasks pulse, completed/failed/cancelled tasks show terminal glyphs, every dot is clickable with a pointer cursor and tooltip, and hovering a dot reveals a delete button. |
| `AgentToolDefinitions.swift` | ~330 | Tool schemas (JSON Schema input contracts + Swift decode types) sent to Anthropic's Messages API. Defines all twelve agent tools: `point_at_element`, `click_element`, `type_text`, `press_keystroke`, `navigate_browser`, `open_new_tab`, `close_tab`, `switch_tab`, `browser_back`, `browser_forward`, `media_control`, `bail_out`. Single source of truth for the tool catalog. |
| `CompanionComputerController.swift` | ~800 | Local computer-control helper. Converts AppKit screen coordinates to Quartz event coordinates, tries `AXPress` at the blue-cursor target, falls back to coordinate CGEvents while restoring the hardware cursor, types text, and posts global media-key events. `typeText` posts per-character `CGEvent`s with `virtualKey` populated (so React/Electron contenteditables see real `keyCode`/`key` fields) and looks up the (character → keystroke) pair via `CompanionKeyboardLayoutMap`. Never touches the clipboard. |
| `CompanionKeyboardLayoutMap.swift` | ~175 | Reverse keyboard-layout lookup powering `typeText`. Caches a `[Character: (virtualKey, modifierFlags)]` map built by enumerating every (virtualKey, modifierState) pair against `UCKeyTranslate` on the user's currently active keyboard layout — works on US QWERTY, Dvorak, AZERTY, JIS, Colemak, etc. without hardcoding. Rebuilds when the active input source changes. Characters no single keystroke can produce (emoji, IME-only chars, dead-key composites) fall back to the Unicode-payload path in `typeText`. |
| `CompanionAccessibilityStateSnapshot.swift` | ~210 | Captures the post-action macOS Accessibility state (frontmost app + window title, focused element role + value + label) and renders it as a compact `[ax] frontmost=…, focused=…` suffix appended to every tool_result in the agent loop. Gives the model unambiguous ground truth about whether an action took effect — `focused=AXTextArea value=""` tells it a text input is ready without it having to infer focus from a screenshot that may not show a caret. Strictly additive; when AX returns nothing (custom-drawn canvases, apps that disabled AX) the suffix is empty and the screenshot remains the only signal. |
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
| `ClaudeAPI.swift` | ~430 | Claude vision API client. Three modes: legacy SSE streaming (used by the onboarding demo pointing flow), non-streaming `analyzeImage`, and `runAgentTurnWithToolUse` (multi-turn tool-use loop with `cache_control` on system + tools for prompt caching). TLS warmup optimization, image MIME detection. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~95 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling and `awaitPlaybackCompletion()` for the agent-loop per-step narration queue. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `DotAnalytics.swift` | ~125 | PostHog analytics integration. Tracks counts/durations only — never raw transcript or response text. |
| `DotDebugLogger.swift` | ~116 | Local file-backed development logger. Writes rotated diagnostic logs to `~/Library/Logs/Dot/dot.log` and mirrors concise lines to stdout. |
| `DotAccountManager.swift` | ~200 | Google sign-in flow + signed-in user state. Opens `<vibe-id>/auth/start?project=dot` in the system browser, handles the `dot://auth?code=…` callback, exchanges the code for an install token, fetches `/auth/me` for usage, and exposes `signIn()` / `signOut()` for the panel. Talks to vibe-id directly. |
| `DotInstallTokenStore.swift` | ~140 | Thread-safe Keychain wrapper for the long-lived install token. Uses the legacy file-based keychain (data-protection keychain needs entitlements we don't ship) plus an in-memory cache so non-MainActor API clients don't pay a SecItem syscall on every request. |
| `DotMemoryStore.swift` | ~280 | Local file-backed implementation of Anthropic's predefined memory tool (`memory_20250818`). Maps view/create/str_replace/insert/delete/rename commands on a virtual `/memories` namespace to real files under `~/Library/Application Support/Dot/memories/`. Hard path-traversal protection: rejects any path that doesn't start with `/memories`, contains `..`/`.` segments, or — after standardization — would escape the on-disk root. Returns the plain-text response shape Anthropic's spec expects. |
| `DotConversationHistoryStore.swift` | ~95 | JSON file persistence for the cross-turn conversation thread. Defines `ConversationExchange` (Codable struct: user transcript + assistant response + ISO8601 recordedAt) and `loadPersistedExchanges()` / `persistExchanges()` / `clearPersistedHistory()` over `~/Library/Application Support/Dot/conversation_history.json`. Decode failures return [] silently — a corrupt file should not block app launch. Atomic writes; auto-creates parent directory. |
| `MemoryInspectorView.swift` | ~200 | SwiftUI section embedded in the menu bar panel for browsing / deleting / wiping the model's persistent memory. Renders one row per `MemoryEntrySummary` from `DotMemoryStore.listAllMemoryEntries()`, with delete buttons, a separate "Forget conversation thread" action, and a "Forget everything" destructive button with confirmation dialog. Pinned entries (under `/memories/pinned/`) are visually distinguished. Phase 3a trust surface. |
| `DotIdleDetector.swift` | ~45 | Wraps `CGEventSource.secondsSinceLastEventType` to report system-wide idle duration. Used by the sleep-cycle scheduler to decide when running a Haiku consolidation pass won't introduce visible latency. Uses the `0xFFFFFFFF` event-type sentinel ("any input event") that Quartz recognizes as a wildcard. |
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
