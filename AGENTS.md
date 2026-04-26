# YardTalk — Agent Instructions

<!-- CLAUDE.md is a symlink to this file. -->

## Overview

YardTalk is a macOS menu bar app that records short narrated screen clips during work sessions and synthesizes them into per-project reports. Forked from [Clicky](https://github.com/farzaa/clicky) (MIT); preserves Clicky's menu bar, screen capture, and overlay foundations while diverging toward session-oriented journaling with local transcription and optional push to a personal assistant.

**Current phase:** rebrand and planning. Implementation has not started. See [`REBRAND-TODO.md`](REBRAND-TODO.md) for Xcode-side renaming tasks that must happen before serious code work.

## Not YardTalk (Python)

There is a separate, unrelated Python dictation app also named YardTalk at `/Users/michaeljones/Projects/yardtalk-py`. They share a name but not a codebase. This repo is the Swift successor. Do not confuse the two — check the repo's language/tooling if you're uncertain which you're in.

## Architecture (planned)

- **App type:** Menu bar-only (`LSUIElement=true`), inherited from Clicky
- **Framework:** SwiftUI with AppKit bridging for `NSPanel` and the capture overlay
- **Transcription:** [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML Parakeet on the Apple Neural Engine), replacing Clicky's AssemblyAI pipeline
- **Synthesis:** Anthropic Claude (Sonnet / Opus) via the Anthropic Swift SDK or direct HTTPS
- **Screen capture:** `ScreenCaptureKit` + `AVAssetWriter` for MP4 video clips with audio baked in
- **Session timeline:** per-project, persisted locally; user reviews before any outbound push
- **NU integration:** `POST /api/v1/sessions/` with PAT auth (`Authorization: Bearer pat_…`), `Idempotency-Key` header, `test_mode` flag for dev pushes. Contract frozen per [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330).

## Core principles

- **Voice is the semantic layer; video is evidence.** Claude synthesizes from narration + clips at end-of-session, not in real time.
- **User is authority.** On-demand oracle pattern: Claude answers when asked mid-session; it does not interrupt.
- **Nothing leaves without an explicit, recent user decision.** No silent background uploads. Three-way end-of-session dialog: upload, queue for later, keep local / delete.
- **Raw artifacts stay local by default.** Only structured summaries are pushed to NU — never clips, transcripts, or screenshots.

## Payload contract (frozen with NU)

```json
{
  "source": "yardtalk-mac/1.0.0",
  "project": "acme-labs-presentation",
  "project_type": "presentation_prep",
  "session_start": "2026-04-21T14:00:00Z",
  "session_end": "2026-04-21T15:30:00Z",
  "summary": "...",
  "accomplishments": ["..."],
  "blockers": ["..."],
  "next_steps": ["..."],
  "references": { "report_url": "file://...", "clip_ids": ["..."] },
  "test_mode": false,
  "schema_version": 1
}
```

Headers: `Authorization: Bearer pat_…`, `Idempotency-Key: <client-generated UUID>`.

## First templates

Ship with two project templates before pen-test support:

1. **Presentation prep** — synthesis produces an outline, talking points, weak spots
2. **Research notes** — synthesis produces annotated reading notes grouped by theme

Pen-test report template is deferred — highest-stakes and most privacy-sensitive. Validate the core loop on lower-stakes templates first.

## Code style & conventions (inherited from Clicky)

- SwiftUI first; AppKit bridging (`NSPanel`, `NSHostingView`) where needed
- All UI state on `@MainActor`; async/await throughout
- Clear names over clever names — `originalQuestionLastAnsweredDate` over `originalAnswered`
- Comments explain *why*, not *what*
- Do not run `xcodebuild` from the terminal — it invalidates TCC (Screen Recording, Accessibility, Microphone) permissions

## Upstream

Clicky remains at `upstream` for future cherry-picks (e.g., useful bug fixes to `ScreenCaptureKit` handling). Syncing will get harder as YardTalk diverges; prefer reading upstream changes and porting deliberately rather than merging after the rebrand pass lands.

## Build

```bash
open yardtalk.xcodeproj
# Select scheme, set signing team, ⌘R
```
