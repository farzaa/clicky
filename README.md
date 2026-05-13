# Hi, this is Dot.

A small AI buddy that lives in your Mac's menu bar. Push-to-talk (Control + Option) to ask it anything — it sees your screen, talks back, and can fly a blue cursor over to the thing it's referring to.

![Dot — an AI buddy that lives on your mac](dot-demo.gif)

Forked from [Clicky](https://github.com/farzaa/clicky) by Farza, then rebranded and extended with shared inference (Anthropic + AssemblyAI + ElevenLabs proxied through a Cloudflare Worker), Google sign-in, and per-user usage tracking so it can be distributed to friends without them needing their own API keys.

## Friends: install the prebuilt app

Go to [https://dot.vibe-research.net](https://dot.vibe-research.net), download the latest build, sign in with Google, and you're done. Inference is on the house.

The rest of this README is for hacking on the source.

---

## Manual setup (developers)

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- The separate [`vibe-id`](https://github.com/Clamepending/vibe-id) backend if you need to change auth, credits, or inference routing

### 1. Backend

There is no per-project Worker in this repo. Dot talks to the central `vibe-id` service at `https://api.accounts.vibe-research.net` for Google sign-in, `/auth/me`, `/chat`, `/tts`, and `/transcribe-token`.

```bash
cd ~/Desktop/projects/vibe-id/worker
npm install
npm exec tsc -- --noEmit
npm exec wrangler -- deploy --dry-run
```

Deploy `vibe-id` only from that repo, after its production smoke checks pass.

### 2. Run a local backend if needed

For backend development, run `vibe-id` locally and point `DotProxyBaseURL` / `VibeIdBaseURL` in `leanring-buddy/Info.plist` at that local server. The checked-in app defaults to production `vibe-id`.

### 3. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app builds as **Dot** with bundle ID `net.vibe-research.dot`. It appears in your menu bar (not the dock). Click the icon to open the panel, sign in with Google, grant the permissions it asks for, and you're good.

### 4. Install locally without Xcode

```bash
./scripts/install-local-dev-app.sh
```

The script installs `/Applications/Dot.app`, signs it with your first available `Developer ID Application` certificate, and falls back to ad-hoc signing if no signing identity is installed.

### Development logs

Dot writes a local rotating diagnostic log here:

```bash
~/Library/Logs/Dot/dot.log
```

Tail it while testing push-to-talk, transcription, Claude responses, TTS, or click/type/media execution:

```bash
./scripts/tail-dot-log.sh
```

The log records raw shortcut transitions, dictation state changes, permission refreshes, AssemblyAI websocket lifecycle, Claude/TTS boundaries, and computer-control actions. It logs transcript and response lengths instead of full spoken text.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for clicking/type/media actions and Accessibility API control
- **Input Monitoring** — for detecting the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. Short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. On first launch the user signs in with Google through the Worker, which mints an install token tied to their account; the token lives in the macOS Keychain and is sent as `Authorization: Bearer …` on every request. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors, plus hidden `[CLICK:…]`, `[TYPE:…]`, and `[MEDIA:…]` tags for computer control. All three upstream APIs are proxied through the Cloudflare Worker, which authenticates the bearer token, enforces per-user daily quotas, and writes a usage event to D1 on every successful call.

## Project structure

```
leanring-buddy/             # Swift source (yes, the typo stays)
  CompanionManager.swift      # Central state machine
  CompanionComputerController.swift # Blue-cursor click/type/media execution
  DotAccountManager.swift     # Google sign-in, Keychain install token, sign-out
  DotDebugLogger.swift        # Local development log writer
  DotAnalytics.swift          # PostHog (counts only — no raw transcript/response)
  CompanionPanelView.swift    # Menu bar panel UI
  ClaudeAPI.swift             # Claude streaming client
  ElevenLabsTTSClient.swift   # Text-to-speech playback
  OverlayWindow.swift         # Blue cursor overlay
  AssemblyAI*.swift           # Real-time transcription
  BuddyDictation*.swift       # Push-to-talk pipeline
worker/                     # Cloudflare Worker (inference gateway)
  src/index.ts                # /auth/*, /chat, /tts, /transcribe-token, /admin/*
  schema.sql                  # D1 schema (users, oauth_states, auth_codes, devices, usage_events)
website/                    # Static download + account + admin pages
  index.html                  # Landing + Sign in + download
  account.html                # Per-user usage dashboard
  admin.html                  # Admin usage dashboard
CLAUDE.md / AGENTS.md       # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

## Credits

- [Clicky](https://github.com/farzaa/clicky) by Farza — the original open-source AI cursor companion this fork started from. Released under MIT.
