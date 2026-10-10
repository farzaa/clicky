# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Clicky is a local-first AI companion running in your browser (`http://localhost:7800`). It connects with your desktop screen, provides real-time voice interaction with guaranteed instant cancellation (`Esc`), and maintains long-term memory across sessions using the **SMRITI memory core**.

All local AI chat is powered by Ollama (Mistral, Qwen 3.5 Vision, etc.) with zero external API keys or cloud dependencies required.

## Architecture

- **App Type**: Localhost Web Application (`http://localhost:7800`)
- **Backend**: Python 3 standard library (`http.server`, `urllib`, `subprocess`, `json`) — zero external pip packages required for the web server
- **Frontend**: Clean single-page dark UI (`web/index.html`) using HTML5, CSS3, and modern vanilla JavaScript
- **AI Chat**: Local Ollama (port `11434`) supporting `mistral:latest` (default fast text model), `qwen3.5:latest` (multimodal vision), and custom Ollama models
- **Screen Perception**: Native macOS silent CLI (`screencapture -x -t jpg`) combined with `sips -Z 1280` downscaling to eliminate TCC permission friction and slash vision token latency
- **Speech-to-Text**: Browser Web Speech API (`SpeechRecognition` / `webkitSpeechRecognition`) with real-time live transcript preview
- **Text-to-Speech**: Browser Web Speech Synthesis (`SpeechSynthesisUtterance`) with guaranteed immediate cancellation via `window.speechSynthesis.cancel()` triggered by the red `[⏹️ Stop Speaking]` button or `Esc` key
- **LTM Memory**: Shared local-first memory via SMRITI core HTTP REST API (`localhost:7798`) reading and writing to `~/.smriti/global`

### SMRITI Memory Architecture

Clicky packages SMRITI to enable a shared long-term memory layer between Clicky, Claude Code, Gemini CLI, and terminal agents on the user's laptop.
* **Global Database**: All tools read and write to `~/.smriti/global`, meaning memories captured by Clicky are instantly visible to terminal agents.
* **REST API Server**: Clicky boots a Python HTTP server on port `7798` (running `scripts/smriti_local_api.py`) for low-latency memory recall and encoding.
* **Turn Flow**: Clicky recalls memories based on user input to inject into the system prompt, and encodes completed conversational turns back to SMRITI.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `web/server.py` | ~295 | Local companion server running on localhost:7800. Handles `/api/chat`, `/api/status`, `/api/capture`, `/api/screenshot`, SMRITI recall/encode, and Ollama integration. |
| `web/index.html` | ~1030 | Responsive dark Web UI. Features real-time voice dictation, Stop Speaking button [Esc], voice toggle, screen preview thumbnail + lightbox, model selector, and SMRITI memory badges. |
| `scripts/smriti_local_api.py` | ~240 | SMRITI HTTP REST API daemon running on port 7798 with memory recall, turn encoding, and health reporting. |
| `run_web.sh` | ~30 | One-click launcher that boots SMRITI daemon, starts Clicky web server, and opens `http://localhost:7800` in the browser. |
| `worker/src/index.ts` | ~142 | Optional Cloudflare Worker proxy for cloud models (Claude, ElevenLabs, AssemblyAI). |

## How to Run

```bash
# Launch Clicky Web Companion and SMRITI daemon:
./run_web.sh

# Or start the server manually:
python3 web/server.py
```

The web interface will open automatically at **`http://localhost:7800`**.

## Code Style & Conventions

- Always use `python3` and `pip3` for Python commands.
- Keep `web/server.py` free of heavy external dependencies; use Python standard libraries wherever possible.
- Optimize for clarity over concision. Use descriptive, self-explanatory variable and method names.
- Screen capture downscaling: Always maintain `sips -Z 1280` when processing screenshots to prevent multimodal model timeouts on Retina displays.
