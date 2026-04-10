# Clicky for Windows

This directory holds the Windows port of Clicky, an AI buddy that lives next
to the cursor, can see the screen, talk back through TTS, and fly to UI
elements it wants to point at.

The macOS reference implementation lives in `../mac/`. The Cloudflare Worker
that proxies the Anthropic, AssemblyAI, and ElevenLabs APIs is shared at
`../worker/` and is reused unchanged.

## Target stack

- **Language / Runtime:** C# 12 on .NET 8 (LTS)
- **UI:** WPF (transparent topmost overlay + tray-only host window). WPF was
  picked over WinUI 3 because click-through, per-monitor DPI, layered
  windows, and `WS_EX_TRANSPARENT` are battle-tested there.
- **Tray icon:** `H.NotifyIcon` (modern Win11-friendly NotifyIcon wrapper)
- **Global hotkey:** `SetWindowsHookEx(WH_KEYBOARD_LL)` low-level keyboard
  hook so modifier-only chords (Ctrl+Alt) work like the Mac CGEventTap.
- **Audio capture:** `NAudio.Wasapi` (`WasapiCapture` at the device's native
  format, then resampled to 16 kHz mono PCM16 for AssemblyAI).
- **Audio playback:** `NAudio` `Mp3FileReader` + `WaveOutEvent` for
  ElevenLabs MP3 playback.
- **Screen capture:** `Windows.Graphics.Capture` via CsWinRT, with
  per-display `GraphicsCaptureItem`s. Falls back to DXGI Desktop Duplication
  on Windows 10 builds without WGC permission prompts.
- **HTTP / SSE:** `System.Net.Http.HttpClient` with `HttpCompletionOption.ResponseHeadersRead`
  for streaming Claude responses.
- **WebSocket:** `System.Net.WebSockets.ClientWebSocket` for the AssemblyAI
  realtime streaming endpoint.
- **Auto-launch:** `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- **Auto-update:** WinSparkle bound through P/Invoke (mirrors Sparkle on Mac).
- **Analytics:** PostHog .NET SDK (mirrors `ClickyAnalytics.swift`).

## Project layout (planned)

```
windows/
  Clicky.sln
  src/
    Clicky.App/                 # WPF host, App.xaml, tray bootstrap
    Clicky.Companion/           # CompanionManager state machine
    Clicky.Audio/               # WASAPI capture + resampler + TTS playback
    Clicky.Capture/             # WGC multi-monitor screenshotter
    Clicky.Hotkey/              # Low-level keyboard hook + chord parser
    Clicky.Overlay/             # Transparent click-through cursor overlay
    Clicky.Api/                 # Claude SSE client + AssemblyAI ws client + ElevenLabs
    Clicky.Pointing/            # [POINT:x,y:label:screenN] parser + element locator
  tests/
    Clicky.Tests/
```

Each user story in `../prd.json` is sized to land in roughly one of these
projects so a single Ralph iteration can complete it end-to-end.
