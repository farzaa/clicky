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

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 20.3+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

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

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://127.0.0.1:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys. You can start from `worker/.dev.vars.example`:

```bash
cp worker/.dev.vars.example worker/.dev.vars
```

Then edit `worker/.dev.vars` with your real keys. The checked-in local dev app reads `ClickyProxyBaseURL` from `leanring-buddy/Info.plist`, which defaults to `http://127.0.0.1:8787`. If you deploy the Worker instead of using `wrangler dev`, change that one plist value to your deployed Worker URL.

### 3. Update the proxy URL in the app

The app uses one plist key for the Worker base URL:

```xml
<key>ClickyProxyBaseURL</key>
<string>http://127.0.0.1:8787</string>
```

The Swift code derives `/chat`, `/tts`, and `/transcribe-token` from that base URL.

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The local fork builds as **Clicky Dev** with bundle ID `com.mark.clicky-dev`, so it can sit beside the original Clicky app. The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### 5. Install locally without Xcode

If you only have Apple's command line tools installed, you can build and install the local fork directly:

```bash
./scripts/install-local-dev-app.sh
```

The script installs `/Applications/Clicky Dev.app`, signs it with your first available `Developer ID Application` certificate, and falls back to ad-hoc signing if no signing identity is installed. Developer ID signing is better for repeated local development because macOS privacy permissions are tied to the app's code identity.

### Development logs

Clicky Dev writes a local rotating diagnostic log here:

```bash
~/Library/Logs/Clicky Dev/clicky-dev.log
```

Tail it while testing push-to-talk, transcription, Claude responses, TTS, or click/type/media execution:

```bash
./scripts/tail-clicky-dev-log.sh
```

The log records raw shortcut transitions, dictation state changes, permission refreshes, AssemblyAI websocket lifecycle, Claude/TTS boundaries, and computer-control actions. It logs transcript and response lengths instead of full spoken text.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for clicking/type/media actions and Accessibility API control
- **Input Monitoring** — for detecting the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. Claude can also emit hidden `[CLICK:x,y:label:screenN]`, `[TYPE:text]`, and `[MEDIA:play_pause|next|previous]` tags when the user asks it to operate the computer. Obvious media-only phrases such as "pause the music" execute locally before the screenshot/model path. All three APIs are proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionComputerController.swift # Blue-cursor click/type/media execution
  ClickyDebugLogger.swift   # Local development log writer
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Three routes: /chat, /tts, /transcribe-token
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@clamepending](https://x.com/clamepending).
