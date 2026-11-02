# clicky-py — the Windows port

Python port of Clicky (the macOS menu-bar companion app in this repo) so it
can run on Windows. Same pipeline, same persona, same [POINT:...] pointing
behavior — rebuilt on PySide6 instead of AppKit/SwiftUI.

## What is ported (MVP)

| macOS piece | Port |
| --- | --- |
| Menu bar icon + floating panel | System tray icon + frameless dark panel |
| Push-to-talk ctrl+option (CGEvent tap) | ctrl+alt system-wide via pynput, plus a hold button in the panel |
| AVAudioEngine mic capture | sounddevice mic stream -> PCM16 16 kHz (numpy) |
| AssemblyAI streaming transcription | Same websocket + turn bookkeeping via the shared proxy token route |
| OpenAI transcription fallback | Upload-based provider (WAV on release), `OPENAI_API_KEY` env var |
| Claude vision + SSE streaming | Same request shape through the proxy `/chat`, streamed `content_block_delta` |
| ElevenLabs TTS | Same payload through proxy `/tts`, played via QMediaPlayer |
| Screen capture (ScreenCaptureKit) | mss multi-monitor JPEG capture, cursor screen first, same labels |
| Blue cursor overlay + flight arcs | Transparent always-on-top Qt overlay, quadratic bezier flight + tangent rotation |
| [POINT:x,y:label:screenN] parsing | Identical regex + coordinate mapping (no AppKit Y-flip on Windows) |
| Conversation memory (last 10) | Same history trimming |

Not ported (yet): onboarding video flow, SAPI replacement of NSSpeech fallback
(requires `pywin32`), PostHog analytics (off by default; set
`CLICKY_PY_POSTHOG_KEY` to enable), Apple Speech provider (Windows has no
equivalent; use OpenAI or AssemblyAI).

## Install & run

```powershell
cd clicky-py
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python main.py
```

Run API keys through the proxy (see `worker/` in the repo root):

```powershell
cd ..\worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY   # etc.
npx wrangler dev            # serves http://127.0.0.1:8787 — clicky-py's default proxy
```

Settings live in `%APPDATA%\ClickyPy\settings.json` (proxy URL, model,
cursor preference). `VOICE_TRANSCRIPTION_PROVIDER=assemblyai|openai`
picks the transcription backend.

## Tests

```powershell
pytest         # pure-python tests: POINT parsing, WAV builder, coordinate math, SSE parsing
```

The GUI itself is not covered by pytest; run `python main.py` and use the tray
icon to poke the panel.
