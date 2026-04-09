# Sewa Companion

Native Linux desktop companion for [Sewa](https://github.com/Yagi-Michael/goober_commander). Adds system-wide voice interaction, screen capture, and pointer overlay — capabilities the browser-based HUD cannot provide.

Connects to Sewa on gubserver via Netbird mesh. All intelligence, routing, and persistence live server-side.

## Status

**Phase 1** — foundation (text chat sync between companion and HUD).

## Architecture

```
Companion (Tauri on Linux)
  → Netbird mesh
    → gubserver (Caddy)
      → Sewa (Phoenix :4000)
```

- **Companion** is a thin client: captures input (mic, screen), renders output (audio, pointer overlay, chat bubbles)
- **Sewa** handles all AI dispatch, command routing, Engram enrichment, chat persistence
- **Auth**: Authentik OIDC → OpenBao token
- **Communication**: Phoenix WebSocket channel (`companion:chat`) for real-time bidirectional sync

## Prerequisites

- NixOS (or any Linux with PipeWire)
- Rust toolchain (`rustup`)
- Node.js 18+
- Tauri CLI: `cargo install tauri-cli --version "^2"`
- Netbird mesh connected to gubserver

## Development

```bash
# Install dependencies
npm install

# Run in dev mode (hot reload)
cargo tauri dev

# Build release
cargo tauri build
```

## Configuration

On first launch, set the Sewa URL in localStorage:

```javascript
localStorage.setItem("sewa_url", "wss://sewa-prod.1-800-goobsquire.lol");
```

Auth token is obtained via OIDC flow and stored in system keyring.

## Design Spec

Full spec: `goober_commander/docs/superpowers/specs/2026-04-08-sewa-companion-design.md`

## Phases

1. **Foundation** (current) — auth, Phoenix channel, text chat sync
2. **Voice** — push-to-talk, STT, TTS
3. **Screen Context** — PipeWire screen capture, vision AI
4. **Pointer Overlay** — transparent overlay, animated pointer, chat bubbles
5. **Polish** — settings UI, auto-launch, reconnection
