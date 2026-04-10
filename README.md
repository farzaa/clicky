# Hi, this is Flowee.
It's a flow-state sidekick that lives next to your cursor. It sees your screen, listens to what you're trying to do, talks back when you need guidance, and can now kick work over to local coding agents when you want execution instead of commentary.

The goal is simple: keep you in flow. You stay on the simulator, the browser, the design, or the bug you just noticed. Flowee handles the context capture, the interpretation, the draft, or the delegation.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

This is the open-source version of Flowee for people who want to hack on it, extend it, wire in new agent workflows, or just understand how a cursor-native sidekick can work on macOS.

Big thanks to [@farzatv](https://x.com/farzatv) for building Clicky and open-sourcing the foundation this version grows from.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Flowee running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running, you can keep iterating in place: ask Flowee to explain what you're seeing, draft something from the current screen, or delegate a coding task into a local agent without breaking flow.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
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

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update `ClickyWorkerBaseURL` in `leanring-buddy/Info.plist` to `http://localhost:8787` while developing.

### 3. Update the proxy URL in the app

The app reads the Worker base URL from `leanring-buddy/Info.plist`. Set `ClickyWorkerBaseURL` to your deployed Worker URL:

```xml
<key>ClickyWorkerBaseURL</key>
<string>https://your-worker-name.your-subdomain.workers.dev</string>
```

For local Worker development, temporarily point that same value to `http://localhost:8787`.

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### 5. Build a standalone launcher for everyday use

Running from Xcode is fine for development, but the app should be installed from a Release build if you want to keep using it normally without Xcode open.

```bash
./scripts/build-launcher.sh
```

That produces:

```bash
build/local-release/launcher/Flowee.app
```

Move that `Flowee.app` into `/Applications` and launch it from there. That app bundle is the launcher, and installing it in `/Applications` is the setup that works properly with the app's login-item registration.

If you want the script to install it for you:

```bash
./scripts/build-launcher.sh --install
```

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with AppKit-backed floating surfaces for the control panel, cursor-adjacent overlays, and delegation logs. Push-to-talk streams audio over a websocket to AssemblyAI, sends transcript + screenshot context to Claude, and plays spoken replies through ElevenLabs TTS. Flowee can route requests into `reply`, `draft`, or `delegate`, and when delegation is selected it can hand work to local coding-agent CLIs in approved workspaces. Claude can also embed `[POINT:x,y:label:screenN]` tags in responses to make the cursor fly to specific UI elements across multiple monitors. All API traffic is proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
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

PRs welcome. If you're using Claude Code, it already knows the codebase. Tell it what part of the flow-state sidekick you want to change and point it at `CLAUDE.md`.

### Install the secret-scanning pre-commit hook

Before your first commit to this repo, run this once:

```bash
git config core.hooksPath .githooks
```

That activates `.githooks/pre-commit`, which blocks commits containing strings that look like real Anthropic, OpenAI, AWS, Slack, GitHub, or ElevenLabs credentials. Placeholder text like `sk-ant-...` in `worker/.dev.vars.example` is intentionally ignored. If you hit a false positive, revise the placeholder so it cannot be mistaken for a real key — do not bypass the hook with `--no-verify` unless you are certain the diff contains no real secret.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
