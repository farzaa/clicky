# YardTalk

A macOS menu bar app that records narrated work sessions — short screen clips with voice narration — and synthesizes them into per-project reports.

Forked from [Clicky](https://github.com/farzaa/clicky) (MIT). YardTalk inherits Clicky's menu bar, screen capture, and overlay foundations, and diverges around:

- **Local transcription** via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet on the Apple Neural Engine), replacing Clicky's AssemblyAI pipeline.
- **Session mode** with video clips and a per-project timeline, instead of single-shot Q&A.
- **Per-project synthesis** via Anthropic Claude at end-of-session, producing structured reports.
- **Optional push** of session summaries to a [NeighborhoodUnited](https://neighborhoodunited.org) personal assistant for cross-project memory.

## Core loop

1. Pick an active project from the menu bar (e.g., `acme-labs-presentation`)
2. Hold the global hotkey to narrate while working — captures a short screen video with voice baked in
3. Each clip becomes a note in the project's timeline: `{video, transcript, timestamp}`
4. At session close, review the generated summary; upload to NU, queue for later, or keep local
5. Raw clips and transcripts stay on-device — only structured summaries are pushed

## Status

Active development as of April 2026. Core recording, transcription, and synthesis pipeline are functional. See [`REBRAND-TODO.md`](REBRAND-TODO.md) for remaining cleanup and upcoming milestones.

**Working:**
- Menu bar panel with project management (create, edit, switch)
- Toggle-hotkey recording (⌃⌥D) with per-display screen selection overlay
- Marker hotkey (⌃⌥M) for flagging moments during recording
- Per-project clip storage with local transcription
- Session grouping with timeline UI (expand clips, delete, QuickLook)
- End-of-session synthesis via Claude (presentation prep + research notes templates)
- BYOK: user supplies their own Anthropic API key, stored in macOS Keychain
- Settings screen for API key management

**Upcoming:** Review/edit dialog (M3), NU PAT flow + upload (M4/M5), outbox (M6)

## Architecture

- Swift / SwiftUI menu bar app (no dock icon), `NSPanel` floating UI
- `ScreenCaptureKit` for screen video + `AVAssetWriter` for MP4 encoding with audio
- `FluidAudio` for local Parakeet STT (CoreML, Apple Neural Engine)
- Anthropic Claude for end-of-session synthesis — BYOK (Bring Your Own Key), API key stored in macOS Keychain, direct calls to `api.anthropic.com`
- NU integration (planned) via `Authorization: Bearer pat_…` + `POST /api/v1/sessions/`, `Idempotency-Key` header, `test_mode` flag for dev pushes

## Principles

- Voice is the semantic layer; video is evidence.
- User is the authority — Claude answers when asked, it doesn't interrupt.
- Nothing leaves without an explicit, recent user decision.
- Raw artifacts stay local; only structured summaries are shared.

## Credits

Built on [Clicky](https://github.com/farzaa/clicky) by [@farzatv](https://x.com/farzatv). The upstream remote is retained for future reference. Original Clicky `LICENSE` preserved per MIT terms.

## License

MIT — see [`LICENSE`](LICENSE).
