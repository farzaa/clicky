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

Help me set up local Settings with my OpenRouter and ElevenLabs keys and get it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- API keys for: [OpenRouter](https://openrouter.ai/keys) and [ElevenLabs](https://elevenlabs.io)

### 1. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run
4. Open Clicky panel > `Settings` tab:
   - Add your OpenRouter API key
   - Add your ElevenLabs API key
   - (Optional) set ElevenLabs voice ID
   - Refresh OpenRouter models and choose one

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk transcription is local Apple Speech, the transcript + screenshot is sent to OpenRouter via streaming SSE, and the response plays through ElevenLabs TTS. OpenRouter can embed `[POINT:x,y:label:screenN]` tags to make the cursor fly to specific UI elements across multiple monitors.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # OpenRouter streaming client + model list fetch
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AppleSpeech*.swift        # Local speech transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
