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
- For **Claude mode** only: Node.js 18+ (for the Cloudflare Worker)
- For **Claude mode** only: a [Cloudflare](https://cloudflare.com) account (free tier works)
- For **Claude mode** only: API keys for [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), and [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker for Claude mode

If you want to use **Claude** in the app, the Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

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

### 2. Run the Worker locally for Claude mode development

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

### 3. Update the proxy URLs in the app for Claude mode

The Claude path has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

### 4. Local model setup

If you want to run Clicky fully on-device, use the app's **Local** inference mode.

1. Open `leanring-buddy/Info.plist` and make sure this key is set:

   ```
   VoiceTranscriptionProvider = apple
   ```

   Local mode is intended to use Apple Speech for transcription.

2. Open `leanring-buddy.xcodeproj` in Xcode and let Swift Package Manager resolve the local model dependencies.

   The built-in MLX path depends on the MLX packages used by the app, including `MLX`, `MLXLMCommon`, and `MLXVLM`. If Xcode shows package resolution issues, run **File > Packages > Resolve Package Versions**.

3. Build and run the app.

4. Open the Clicky menu bar panel and switch the inference selector from **Claude** to **Local**.

5. Choose your local backend:

   - **MLX** for the built-in on-device model
   - **LM Studio** to use any model currently loaded in LM Studio on your Mac

6. If you choose **LM Studio**, enter the server URL in the panel.

   The default is:

   ```
   http://localhost:1234
   ```

   Clicky expects LM Studio's local server to be running and any model to already be loaded in LM Studio.

7. Wait for the selected local backend to finish preparing.

   The first MLX run may download and prepare the model before it is ready. LM Studio mode validates the server URL and checks for a loaded model.

In **Local** mode:
- chat responses come from either the built-in MLX model or LM Studio, depending on the selected local backend
- speech playback uses the local speech synthesizer client
- transcription uses Apple Speech when `VoiceTranscriptionProvider` is set to `apple`

In **Claude** mode:
- chat responses go through the Cloudflare Worker to Claude
- transcription can use the configured provider from `Info.plist`
- speech playback goes through the Worker to ElevenLabs

You do **not** need the Cloudflare Worker, Anthropic, AssemblyAI, or ElevenLabs keys just to run the local MLX or LM Studio path.

### 5. Open in Xcode and run

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

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk always captures mic audio locally and sends screenshots of your screen into the response pipeline. From there, Clicky can run in two modes:

- **Local**: transcript is captured with Apple Speech, responses come from either the built-in MLX model or an LM Studio local server, and speech playback uses the local speech synthesizer
- **Claude**: transcript, chat, and TTS use the configured cloud providers, with Claude, AssemblyAI, and ElevenLabs all proxied through the Cloudflare Worker

Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  Local-AI-Mode/            # On-device MLX + LM Studio chat backends and local speech synthesis
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Three routes: /chat, /tts, /transcribe-token
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
