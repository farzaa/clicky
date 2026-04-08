# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

### Option 1: Local-first (Recommended — No API keys needed)

Run 100% locally on your Mac. Vision, speech-to-text, and text-to-speech all run on your machine via a local FastAPI server.

**Prerequisites:**
- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Python 3.9+ with pip
- ~8 GB RAM (tested on 18 GB M3 Pro; fits in ~10 GB working set)

**Setup:**

```bash
cd local-worker

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Download models (~6 GB, one-time, goes to ~/.clicky-local/models/)
python setup_models.py

# Start the server (keep this running)
uvicorn main:app --host 127.0.0.1 --port 8787 --log-level info
```

Then open Xcode, build, and run. The app will auto-connect to the local server.

**Models used:**
- **Vision**: Qwen2.5-VL-7B-Instruct (4-bit MLX) — ~5.5 GB
- **Speech-to-text**: MLX-Whisper base — ~290 MB
- **Text-to-speech**: Kokoro-82M ONNX — ~330 MB

---

### Option 2: Cloud-based (Original — Requires API keys)

Use cloud APIs via a Cloudflare Worker proxy. No local GPU/memory constraints.

**Prerequisites:**
- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

**Setup:**

#### 2.1 Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

#### 2.2 Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `clicky-proxy` to find them all.

#### 2.3 Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

---

## Build and run

Whether you chose local or cloud, the next steps are the same:

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

If you want the full technical breakdown, read `AGENTS.md` (or `CLAUDE.md` — they're the same file). But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk captures audio, sends the transcript + screenshot to a vision model via streaming SSE, and plays the response through TTS. The model can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

**Two modes:**
- **Local** (recommended): Vision (Qwen2.5-VL), TTS (Kokoro), and STT (Whisper) all run locally via a FastAPI server. No API keys, no network calls beyond localhost.
- **Cloud** (original): All three services proxied through a Cloudflare Worker that calls Anthropic Claude, ElevenLabs, and AssemblyAI APIs.

## Project structure

```
leanring-buddy/                      # Swift source (yes, the typo stays)
  CompanionManager.swift               # Central state machine
  CompanionPanelView.swift             # Menu bar panel UI
  ClaudeAPI.swift                      # Claude/local vision streaming client
  ElevenLabsTTSClient.swift            # ElevenLabs TTS (cloud mode only)
  LocalWhisperTranscriptionProvider.swift  # Local Whisper provider
  OverlayWindow.swift                  # Blue cursor overlay
  AssemblyAI*.swift                    # AssemblyAI provider (cloud mode only)
  BuddyDictation*.swift                # Push-to-talk pipeline

local-worker/                        # FastAPI server for local inference
  main.py                              # /chat, /tts, /transcribe endpoints
  models/
    vision_model.py                    # Qwen2.5-VL-7B via mlx-vlm
    tts_model.py                       # Kokoro-82M ONNX synthesis
    whisper_model.py                   # MLX-Whisper transcription
  setup_models.py                      # Auto-download models to ~/.clicky-local/models/
  requirements.txt                     # Python dependencies

worker/                              # Cloudflare Worker proxy (cloud mode only)
  src/index.ts                         # Three routes: /chat, /tts, /transcribe-token

AGENTS.md (CLAUDE.md)                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
