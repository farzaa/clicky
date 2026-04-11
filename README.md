# Hi, this is Deb.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

![Deb — an ai buddy that lives on your mac](deb-demo.gif)

This is the open-source version of Deb for those that want to hack on it, build their own features, or just see how it works under the hood.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Python 3.11+ (for the FastAPI backend)
- API keys for: [Anthropic](https://console.anthropic.com), [OpenAI](https://platform.openai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the FastAPI backend

The backend is a thin API service that holds your keys, proxies model/TTS/token requests, and now boots with a Postgres-backed storage layer for users, auth sessions, workspaces, and virtual filesystem entries. The macOS app talks to the backend, and the backend talks to the providers.

```bash
cd backend
docker compose up -d postgres
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
```

Add your secrets to `backend/.env`:

```env
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
DATABASE_URL=postgresql+asyncpg://deb:deb@127.0.0.1:5432/deb
OPENAI_API_KEY=
OPENROUTER_API_KEY=
```

Run it locally:

```bash
uvicorn app.main:app --reload
```

This starts the API on `http://127.0.0.1:8000`.

### 2. Point the app at the backend

Set `DebBackendBaseURL` in `leanring-buddy/Info.plist` to your local or hosted FastAPI base URL.

For local development, the default value is already:

```xml
<key>DebBackendBaseURL</key>
<string>http://127.0.0.1:8000</string>
```

### 3. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk records audio locally, sends it to OpenAI transcription, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. The model and TTS calls go through a FastAPI backend.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  OpenAIAudioTranscriptionProvider.swift # OpenAI voice transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
backend/                 # FastAPI backend
  app/main.py               # FastAPI app startup and middleware
  app/agent/                # Provider-backed backend agent loop
  app/auth_router.py        # Register/login/me/logout endpoints
  app/database.py           # Async Postgres engine and session helpers
  app/models.py             # Users, workspaces, memberships, VFS entries
  app/workspaces_service.py # Shared workspace bootstrap helper
  app/workspaces_router.py  # Create/list/get/launch workspace endpoints
  app/routes.py             # /chat, /tts
worker/                  # Legacy Cloudflare Worker proxy
  src/index.ts              # Older three-route proxy implementation
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
