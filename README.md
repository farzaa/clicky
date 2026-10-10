# Clicky Companion with SMRITI (`clicky-smriti`)

An intelligent local AI companion that lives in your browser, sees your screen, talks with you, provides instant voice controls with guaranteed speech stop (`Esc`), and remembers everything across sessions using **SMRITI local-first long-term memory**.

Works **out-of-the-box with zero API keys** using local models via Ollama.

---

## ⚡ Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/smriti-memcore/clicky-smriti.git
cd clicky-smriti

# 2. Launch Clicky
./run_web.sh
```

This single command:
1. Boots the local **SMRITI memory daemon** on port `7798` (`~/.smriti/global`).
2. Starts the **Clicky Web Companion server** on port `7800`.
3. Opens **`http://localhost:7800`** in your default browser.

---

## 🌟 Key Features

- **⏹️ Instant Speech Stop Control**: Never worry about AI talking non-stop. Hit **`Esc`** at any moment or click the prominent red **`⏹️ Stop Speaking`** button to immediately silence speech via `window.speechSynthesis.cancel()`.
- **🔊 Voice Toggle**: Switch voice output on or off with a single click.
- **📷 Native Screen Awareness**: Automatically captures your active desktop silently via macOS's native `screencapture` CLI, downscaled via `sips` to optimize vision token compute. No TCC permission loops or modal crashes.
- **🧠 SMRITI Long-Term Memory**: Shared local memory layer (`~/.smriti/global`) connecting Clicky, Smriti Desktop App, Claude Code, Gemini CLI, and terminal agents. Every conversation turn is encoded into your memory palace and recalled in future conversations.
- **🎙️ Web Speech Dictation**: Click the **`🎙️`** microphone button to speak with real-time live transcription.
- **🦙 Zero API Keys via Ollama**: Runs entirely on your Mac using local models:
  - **`mistral:latest`** (Default — ultra-fast text chat)
  - **`qwen3.5:latest`** (Multimodal vision chat for inspecting screen contents)
  - Any custom model in your local Ollama library.

---

## 📁 Repository Structure

```
├── run_web.sh              # One-click launcher for SMRITI + Web Companion
├── web/
│   ├── server.py           # Local HTTP companion server (port 7800)
│   └── index.html          # Modern dark Web UI with voice & screen controls
├── scripts/
│   └── smriti_local_api.py # SMRITI REST API daemon (port 7798)
├── worker/
│   └── src/index.ts        # Optional Cloudflare Worker proxy for cloud models
├── AGENTS.md               # Architecture spec and agent instructions
└── README.md               # Project documentation
```

---

## 🧠 SMRITI Memory Architecture

Clicky integrates the **SMRITI Neuro-Inspired Memory Architecture** to maintain a persistent episodic and semantic memory palace across your workflow:

- **Local Storage**: All memories are stored locally on your machine at `~/.smriti/global/palace/palace.json`.
- **Cross-Tool Sharing**: Memories created in Clicky are instantly accessible by terminal agents and the [**Smriti Desktop App**](https://github.com/smriti-memcore/Smriti-Desktop-App).
- **Local HTTP Daemon**: Clicky manages a high-performance HTTP server on `http://127.0.0.1:7798` that automatically handles memory recall before each AI turn and encodes new conversational knowledge.

---

## 🛠️ Prerequisites

- **macOS** (Apple Silicon recommended)
- **Python 3.10+** (with `pip3`)
- **Ollama** for local AI models:
  ```bash
  brew install ollama
  ollama run mistral
  ```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
