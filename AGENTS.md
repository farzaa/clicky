# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via OpenAI audio transcription (`whisper-1` by default), and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a hosted backend — nothing sensitive ships in the app. The app reads its backend base URL from `ClickyBackendBaseURL` in `Info.plist`, so local dev can point at FastAPI while older deployments can still use a compatible proxy.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via hosted backend with SSE streaming
- **Speech-to-Text**: OpenAI audio transcription (`whisper-1` by default) via hosted backend upload proxy, with Apple Speech as the local fallback
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via hosted backend
- **Backend Storage**: Postgres via async SQLAlchemy for users, workspaces, saved agents, memberships, and virtual filesystem entries
- **Backend Auth**: Email/password auth with bearer sessions stored in Postgres
- **Backend Agent Loop**: FastAPI-hosted iterative agent loop with OpenAI Responses and OpenRouter provider adapters, abortable runs, multimodal screenshot message support, backend-owned tools (including `companion.point`), and a `just-bash` powered workspace shell tool
- **Saved Agents**: Each workspace is seeded with a default Clicky agent row in Postgres that stores a reusable system prompt, provider, and model
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### Hosted Backend

The app never calls external APIs directly. All requests go through a backend service that holds the real API keys as secrets. The new default backend is FastAPI (`backend/app/main.py`), and it preserves the chat/tts/transcribe contract from the legacy Cloudflare Worker (`worker/src/index.ts`) while adding dedicated document parsing routes.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcriptions` | `api.openai.com/v1/audio/transcriptions` | Whisper upload transcription |
| `POST /parse` | Docling + OCR providers | Topic-aware PDF parsing with TOC/header routing, OCR fallback, and markdown artifact output |

Backend env vars: `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `DATABASE_URL`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `MISTRAL_API_KEY` (optional, required for handwritten-mode parsing), `MISTRAL_OCR_MODEL` (optional override)

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~80 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — OpenAI or Apple Speech. |
| `OpenAIAudioTranscriptionProvider.swift` | ~319 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV to the hosted backend transcription proxy on release, returns the finalized transcript. |
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
| `AppBundleConfiguration.swift` | ~32 | Runtime configuration reader for keys stored in the app bundle Info.plist, including `ClickyBackendBaseURL`. |
| `backend/app/agent/contracts.py` | ~70 | Shared agent request/response models, message/tool types, and run status shapes. |
| `backend/app/agent/defaults.py` | ~10 | Default Clicky agent settings, including the saved system prompt, provider, and model used when seeding new workspaces. |
| `backend/app/agent/bash_tool.py` | ~400 | Backend workspace bash tool. Serializes a Postgres-backed workspace into a `just-bash` virtual filesystem request, runs the shell, and persists the resulting filesystem snapshot back into `workspace_entries`. |
| `backend/app/agent/postgres_workspace_filesystem.mjs` | ~160 | Custom `just-bash` filesystem implementation backed by serialized workspace entries instead of disk. Delegates shell filesystem calls to an in-memory virtual tree and exports a snapshot for Postgres persistence. |
| `backend/app/agent/just_bash_runner.mjs` | ~60 | Small Node runner that executes `just-bash` against the custom Postgres-workspace filesystem and returns structured stdout/stderr/exit code JSON plus the final filesystem snapshot to the Python backend. |
| `backend/app/agent/router.py` | ~145 | FastAPI routes for running, aborting, and discovering backend agent tools, including `companion.point` and `workspace.run_bash`. |
| `backend/app/agent/loop/service.py` | ~140 | Core iterative agent loop that calls providers, executes tools, and supports abortable runs. |
| `backend/app/agent/loop/tool_handler.py` | ~390 | Backend-owned tool execution for `companion.point`, workspace listing/reading/writing, and `just-bash` shell execution inside Postgres-backed virtual filesystems. |
| `backend/app/agent/loop/abort_registry.py` | ~50 | In-memory run registry that tracks abort requests and attached asyncio tasks. |
| `backend/app/agent/provider/openai_responses.py` | ~170 | OpenAI Responses API adapter for the backend agent loop, including multimodal screenshot input support. |
| `backend/app/agent/provider/openrouter_chat_completions.py` | ~170 | OpenRouter Chat Completions adapter for the backend agent loop, including multimodal screenshot input support. |
| `backend/app/main.py` | ~46 | FastAPI app startup, shared async HTTP client lifecycle, CORS middleware configuration, and router registration. |
| `backend/app/auth.py` | ~50 | Bearer-token authentication dependency that resolves the current user from Postgres-backed auth sessions. |
| `backend/app/auth_router.py` | ~145 | Auth routes for register, login, current-user lookup, and logout. Registration now auto-creates a default workspace and root folder. |
| `backend/app/database.py` | ~45 | Async Postgres engine/session helpers, connectivity verification, and schema bootstrap utilities. |
| `backend/app/models.py` | ~360 | SQLAlchemy models for users, auth sessions, saved agents, workspaces, memberships, and virtual filesystem entries. |
| `backend/app/routes.py` | ~110 | Hosted backend routes for `/chat`, `/tts`, `/transcriptions`, and `/health`. |
| `backend/app/parsing/router.py` | ~13 | FastAPI parsing router for `/parse` with active document-topic parsing endpoint. |
| `backend/app/parsing/contracts.py` | ~109 | Parse request/response contracts including topic, source kind, OCR/backend controls, and topic page markdown outputs. |
| `backend/app/parsing/service.py` | ~166 | Parsing service orchestration. Resolves local/remote PDF inputs, builds parse config, runs topic parsing pipeline, and returns structured response metadata. |
| `backend/app/parsing/course_pdf_ingest/pipeline.py` | ~680 | Core parsing workflow for file/folder/topic modes, topic cache checks, TOC/header/OCR topic location, handwritten-mode routing, and topic markdown emission. |
| `backend/app/parsing/course_pdf_ingest/topic_locator.py` | ~356 | Topic locator using PDF outline, printed TOC parsing, and page-header chunking with fuzzy matching and local page validation. |
| `backend/app/parsing/course_pdf_ingest/ocr_fallback.py` | ~1208 | OCR fallback and provider orchestration (RapidOCR, GLM-OCR, OLMOCR, Mistral OCR), page rendering, quality scoring, and OCR markdown generation. |
| `backend/app/parsing/course_pdf_ingest/docling_backend.py` | ~101 | Docling backend strategy selection and pipeline options wiring. |
| `backend/app/parsing/course_pdf_ingest/normalize.py` | ~712 | Docling output normalization into document/pages/sections/blocks JSON plus page and section markdown content. |
| `backend/app/parsing/course_pdf_ingest/writer.py` | ~193 | Artifact writer for normalized outputs, page/section markdown, figure asset references, and OCR-enriched exports. |
| `backend/app/parsing/course_pdf_ingest/config.py` | ~111 | Parse profiles and backend/OCR config model. |
| `backend/app/parsing/course_pdf_ingest/utils.py` | ~77 | Shared hashing, slug/naming, JSON serialization, and output directory helpers. |
| `backend/app/security.py` | ~50 | Password hashing and session-token helpers for backend auth. |
| `backend/app/workspaces_service.py` | ~55 | Shared helper that creates a workspace, membership row, root directory entry, and default saved Clicky agent. |
| `backend/app/workspaces_router.py` | ~400 | Workspace CRUD-lite endpoints, including backend launch/stop state transitions plus authenticated file upload and file read APIs backed by `workspace_entries`. |
| `backend/docker-compose.yml` | ~14 | Local Postgres container for backend development. |
| `worker/src/index.ts` | ~142 | Legacy Cloudflare Worker proxy. The current FastAPI backend replaces it for `/chat` and `/tts`. |

## Build & Run

```bash
# Start the backend if you're developing locally
cd backend
docker compose up -d postgres
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
cd app/agent
npm install
cd ../..
uvicorn app.main:app --reload

# Open in Xcode
open leanring-buddy.xcodeproj

# Point `ClickyBackendBaseURL` in Info.plist at your backend URL

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## FastAPI Backend

```bash
cd backend
docker compose up -d postgres
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
cd app/agent
npm install
cd ../..

# Start local development server
uvicorn app.main:app --reload
```

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
