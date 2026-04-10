# Sewa Companion

Native Linux desktop companion for [Sewa](https://github.com/Yagi-Michael/goober_commander) — extends the HUD with push-to-talk voice, screen capture, pointer overlay, and bidirectional chat sync.

## Architecture

```
Companion (Tauri v2)
  → Netbird mesh (WireGuard)
    → gubserver (Caddy)
      → Sewa (Phoenix :4000)
```

The companion is a thin client. All AI dispatch, command routing, STT/TTS proxying, and data persistence live in Sewa. The companion handles mic capture, screen capture, overlay rendering, and local settings.

## Features

- **Text chat** — bidirectional sync with Sewa HUD via Phoenix channel
- **Push-to-talk voice** — global hotkey, mic capture via Web Audio API, streamed to Sewa for STT (AssemblyAI) + AI response + TTS (ElevenLabs)
- **Screen capture** — XDG Desktop Portal via ashpd, auto-captured alongside voice, uploaded to Sewa for vision context
- **Pointer overlay** — transparent, click-through, always-on-top overlay with animated pointer, chat bubbles, region highlights, and multi-step chains
- **Settings** — audio devices, screenshot quality, overlay appearance, autostart, and hotkey reference
- **OIDC auth** — Authentik login → OpenBao token, stored in system keyring until expiry

## Prerequisites

- Linux (NixOS recommended — `shell.nix` provided)
- Rust 1.75+ and Cargo
- Node.js 20+
- Tauri CLI: `cargo install tauri-cli`
- Netbird mesh connection to gubserver

## Development

```bash
nix-shell          # NixOS: loads all dependencies
npm run dev        # Start in dev mode (hot reload)
npm run build      # Release build
```

### Configuration

On first launch, the companion opens your browser to Authentik for OIDC login. After authentication, the token is stored in your system keyring.

Settings are accessible via the gear icon in the chat window:

| Setting | Storage | Default |
|---------|---------|---------|
| Sewa URL | localStorage | `wss://sewa-prod.1-800-goobsquire.lol` |
| Authentik URL | localStorage | `https://auth.1-800-goobsquire.lol` |
| Push-to-talk hotkey | Built-in | `Ctrl + Space` |
| Audio input/output | localStorage | System default |
| Screenshot quality | localStorage | 0.80 |
| Auto-capture with voice | localStorage | On |
| Overlay dismiss timeout | localStorage | 5s |
| Animation speed | localStorage | Normal |
| Launch on login | XDG autostart | Off |
| Auth token | System keyring | — |

## Connected Repos

- **[goober_commander](https://github.com/Yagi-Michael/goober_commander)** — Sewa backend (Phoenix API, channels, AI dispatch)
- **[gubserver](https://github.com/Yagi-Michael/gubserver)** — Infrastructure (Caddy reverse proxy, Authentik, OpenBao)

## Phases

1. ✅ Foundation — Tauri scaffold, Phoenix channel chat sync, system tray
2. ✅ Voice — server-side STT/TTS (goober_commander)
3. ✅ Screen Context — server-side screenshot storage (goober_commander)
4. ✅ Pointer Overlay — transparent overlay, animations, multi-monitor
5. ✅ Polish — OIDC auth, client-side voice, screen capture, settings, reconnection, autostart

Design spec: `goober_commander/docs/superpowers/specs/2026-04-08-sewa-companion-design.md`
