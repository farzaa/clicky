# Sewa Companion — Agent Instructions

## Overview

Tauri v2 desktop companion for Sewa. System tray app on Linux that provides voice interaction, screen capture, and pointer overlay. Connects to Sewa on gubserver via Phoenix WebSocket channel over Netbird mesh.

## Architecture

- **Framework**: Tauri v2 (Rust backend + HTML/CSS/JS frontend)
- **Communication**: Phoenix channel WebSocket to Sewa (`/socket/companion`)
- **Auth**: Authentik OIDC → OpenBao token, stored in system keyring
- **Screen Capture**: PipeWire/XDG Desktop Portal (Phase 3)
- **Voice**: Web Audio API for mic, server-side STT/TTS (Phase 2)
- **Pointer Overlay**: Transparent always-on-top window (Phase 4)

## Key Files

| File | Purpose |
|------|---------|
| `src-tauri/src/main.rs` | Tauri entry point, system tray, Rust commands |
| `src-tauri/Cargo.toml` | Rust dependencies |
| `src-tauri/tauri.conf.json` | Tauri config (window, tray, permissions) |
| `src/index.html` | App shell |
| `src/main.js` | Frontend: auth state, WebSocket, chat rendering |
| `src/style.css` | Dark theme matching Sewa HUD |

## Build & Run

```bash
npm install
cargo tauri dev     # development with hot reload
cargo tauri build   # release build
```

Requires: Rust toolchain, Node.js 18+, Tauri CLI (`cargo install tauri-cli --version "^2"`).

## Conventions

- Rust for system APIs (tray, global hotkeys, PipeWire, keyring)
- JavaScript for UI logic and WebSocket handling
- Dark theme: `#0a0a0f` background, `#1a1a2e` borders, matching Sewa HUD
- All intelligence is server-side — companion never calls AI APIs directly
- Companion communicates exclusively with Sewa via Phoenix channel + REST
- Secrets never stored in the app — only the OpenBao token (in system keyring)

## Connected Repos

- **goober_commander** (Sewa): `~/projects/goober_commander` — server-side API, chat persistence, AI dispatch
- **gubserver**: `~/projects/gubserver` — Caddy, OpenBao, Authentik infra

## Design Spec

`~/projects/goober_commander/docs/superpowers/specs/2026-04-08-sewa-companion-design.md`
