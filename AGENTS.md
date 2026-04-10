# CLAUDE.md — sewa-companion

## Overview

Tauri v2 desktop companion for Sewa. Thin client — all intelligence is server-side.

## Architecture

- **Rust backend** (`src-tauri/src/`): system tray, global hotkeys, XDG portal screenshot, OIDC callback server, keyring, autostart, overlay window management
- **JS frontend** (`src/`): Phoenix WebSocket client, chat UI, voice capture/playback, settings panel
- **Communication**: Phoenix channels over WebSocket to Sewa (`/socket/companion`)
- **Auth**: Authentik OIDC → OpenBao tokens (via Sewa `/api/companion/token`)

## Key Files

| File | Responsibility |
|------|---------------|
| `src-tauri/src/main.rs` | Tauri setup, tray menu, global shortcuts (Escape, push-to-talk) |
| `src-tauri/src/overlay.rs` | Per-screen overlay windows (transparent, click-through, always-on-top) |
| `src-tauri/src/auth.rs` | OIDC callback localhost server, keyring read/write/delete |
| `src-tauri/src/screenshot.rs` | XDG Desktop Portal capture, JPEG resize/compress |
| `src-tauri/src/autostart.rs` | XDG autostart .desktop file management |
| `src/main.js` | Integration hub: connects auth, voice, screenshot, settings, reconnection |
| `src/auth.js` | OIDC flow orchestration, token exchange, and expiry handling |
| `src/voice.js` | Mic capture (MediaRecorder), companion:voice channel, TTS playback |
| `src/settings.js` | Settings panel logic, device enumeration, hotkey recording |
| `src/settings.html` | Settings panel markup (6 sections) |
| `src/settings.css` | Settings styles |
| `src/style.css` | Main chat window styles |
| `src/index.html` | App entry point |
| `src/overlay.js` | Pointer/region/chain rendering with animations |
| `src/overlay.html` | Overlay window markup |
| `src/overlay.css` | Overlay styles (pointer, bubbles, region mask) |

## Build Commands

```bash
nix-shell          # Load NixOS dev environment
npm run dev        # Dev mode with hot reload
npm run build      # Release build
cargo check --manifest-path src-tauri/Cargo.toml  # Rust type check
```

## Conventions

- **Rust** for system APIs (screen capture, keyring, autostart, hotkeys)
- **JavaScript** for UI rendering and WebSocket communication
- **No bundler** — plain JS loaded directly by Tauri webview
- **All AI intelligence server-side** — companion never calls Claude/STT/TTS directly
- **Phoenix channel protocol** — messages are `[joinRef, ref, topic, event, payload]` arrays
- **Two channels**: `companion:chat` (text + pointers) and `companion:voice` (audio + transcripts)
- **Settings in localStorage** (non-sensitive) and system keyring (tokens)
- **Dark theme**: `#0a0a0f` background, `#3b82f6` blue accent, `#e0e0e8` text

## Connected Repos

- **goober_commander** — Sewa backend at `~/projects/goober_commander`
- **gubserver** — Infrastructure at `~/projects/gubserver`
