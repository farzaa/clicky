Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

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

Help me set up everything — the local GPT-5.5/Deepgram proxy with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 20.18.1+ (for the local GPT-5.5/voice proxy)
- Codex CLI authenticated with ChatGPT OAuth for GPT-5.5 chat
- A Deepgram API key, or Agent Vault broker access to Deepgram
- Optional: a [Cloudflare](https://cloudflare.com) account if you also want to run the legacy Worker

### 1. Set up the Codex GPT-5.5 OAuth chat proxy

This fork routes `/chat` to a local Node proxy that uses your Codex/ChatGPT OAuth session and `gpt-5.5`. The proxy reads `~/.codex/auth.json`, so keep it local and never deploy it to Cloudflare.

```bash
codex login
cd codex-gpt55-proxy
cp .env.example .env
# Set DEEPGRAM_API_KEY in .env, or configure the AGENT_VAULT_* broker variables instead.
npm install
npm start
```

The app is preconfigured to call `http://127.0.0.1:8877/chat`.

### 2. Voice services

This fork uses the same local proxy for voice:

- `/transcribe` sends recorded push-to-talk audio to Deepgram Listen.
- `/tts` sends responses to Deepgram Speak and returns MP3 audio.

The app is preconfigured to use Deepgram via the local proxy, so no Cloudflare Worker is required for the default local setup. Keep secrets in `codex-gpt55-proxy/.env` (ignored by git) or broker them through Agent Vault.

### 3. Optional: legacy Cloudflare Worker

If you want to test or maintain the original Worker routes, install and deploy it separately:

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
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

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ASSEMBLYAI_API_KEY=***
ELEVENLABS_API_KEY=***
ELEVENLABS_VOICE_ID=...
```

### 3. Update the proxy URLs in the app

This fork defaults chat to the local GPT-5.5 OAuth proxy in `CompanionManager.swift`:

```swift
private static let workerBaseURL = "http://127.0.0.1:8877"
```

Voice transcription and TTS also use the same local proxy by default: `http://127.0.0.1:8877/transcribe` and `http://127.0.0.1:8877/tts`.

### 4. Open in Xcode and run

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

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk records audio, sends the final WAV to Deepgram through the local proxy, sends the transcript + screenshot to GPT-5.5 through the local Codex OAuth proxy via streaming SSE, and plays the response through the local Deepgram TTS route. The model can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Anthropic-shaped SSE client used by the GPT-5.5 proxy
  ElevenLabsTTSClient.swift # Text-to-speech playback through the local TTS route
  DeepgramAudioTranscriptionProvider.swift # Push-to-talk transcription through the local proxy
  AssemblyAI*.swift         # Legacy real-time transcription provider
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Legacy Cloudflare Worker proxy
  src/index.ts              # Legacy voice service routes: /tts, /transcribe-token; legacy /chat remains
codex-gpt55-proxy/       # Local GPT-5.5 Codex OAuth + Deepgram voice proxy
  src/server.mjs            # Translates Anthropic-shaped Clicky chat to Codex Responses API and exposes /tts + /transcribe
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
