# Rebrand TODO

Tasks to complete the Clicky → YardTalk transition. Xcode-side tasks must be done **in the IDE** (not from the terminal) — `.pbxproj` and asset catalogs are too fragile to hand-edit.

## In Xcode

- [ ] Rename `leanring-buddy` directory and scheme → `yardtalk` (File → Rename; Xcode updates project references)
- [ ] Rename targets: `leanring-buddy` → `yardtalk`, `leanring-buddyTests` → `yardtalkTests`, `leanring-buddyUITests` → `yardtalkUITests`
- [ ] Set `CFBundleName` and `CFBundleDisplayName` → `YardTalk` (currently still `Clicky` in `.pbxproj` build settings)
- [ ] Set `PRODUCT_NAME` → `YardTalk` (currently still `Clicky` in `.pbxproj`)
- [ ] Update `INFOPLIST_KEY_NSScreenCaptureUsageDescription` in build settings (`.pbxproj` still says "Clicky needs…" and overrides `Info.plist`)
- [ ] Set `CFBundleIdentifier` (e.g. `com.yardtalk.app`). The Python YardTalk does not set a bundle ID in its `setup.py`, so no collision risk on this machine.
- [ ] Register `yardtalk://` URL scheme in `CFBundleURLTypes` (used for NU signed deep-links later)
- [ ] Remove PostHog SPM package from the project (code is already stubbed out, but the package reference remains in `.pbxproj`)
- [ ] Replace app icon in `Assets.xcassets` (temporary placeholder is fine)
- [ ] Set signing team under Signing & Capabilities
- [ ] Rename `ClickyAnalytics.swift` → `Analytics.swift` (or remove entirely) and update the enum name + all call sites
- [ ] Update `appcast.xml` / `SUFeedURL` once Sparkle updates are wired (currently points to `makesomething-mac-app`)

## Command-line safe

- [x] Grep for `clicky`, `Clicky`, `CLICKY`, `farzaa`, `farzatv` across the codebase; update user-facing strings; leave attribution in README/LICENSE intact
- [x] Decide fate of `ClickyAnalytics.swift` — stubbed out (all no-ops, PostHog removed)
- [x] Remove PostHog dependency if analytics is out of scope for v1 — code removed; SPM package ref in `.pbxproj` needs removal in Xcode
- [ ] Replace `clicky-demo.gif` and `dmg-background.png` once YardTalk has its own look
- [x] Update any functional URLs (worker endpoints, download links, feedback channels) — keep attribution links

## Cloudflare Worker (`worker/`)

Clicky's worker proxies AssemblyAI, ElevenLabs, and Claude. For YardTalk:

- [x] **Delete AssemblyAI endpoint** — FluidAudio runs locally, no cloud STT needed
- [x] **Delete ElevenLabs endpoint** — no TTS planned for v1
- [x] **Claude proxy no longer required** — switched to BYOK (Bring Your Own Key); users supply their own Anthropic API key in Settings, stored in macOS Keychain, app calls `api.anthropic.com` directly. Optional proxy URL override retained in `ClaudeAPI` for enterprise/team setups.
- [x] **No NU endpoint needed** — NU's PAT auth is designed for direct client calls

## Replace Clicky's core loop with YardTalk's

- [ ] Strip push-to-talk → AssemblyAI → Claude → ElevenLabs → cursor-pointing pipeline
- [x] Add FluidAudio as a Swift Package dependency
- [ ] Build:
  - [x] Project model + picker UI (menu bar dropdown)
  - [x] Session mode with toggle-hotkey video capture (`SCStream` + `AVAssetWriter`, ⌃⌥D toggle, ⌃⌥M markers)
  - [x] Display selection overlay (full-screen per-display, shown on hotkey press)
  - [x] Per-session timeline with clip expansion, deletion, QuickLook
  - [ ] End-of-session review/edit dialog (M3)
  - [x] Synthesis pipeline → Claude → structured payload (BYOK, direct API calls)
  - [x] Synthesis UI: progress indicator, summary preview, error+retry, manual synthesize button
  - [ ] Three-way upload dialog (upload now / queue / keep local or delete) (M5)
  - [ ] Outbox view for queued pushes (M6)
  - [x] Keychain service for secure credential storage
  - [x] BYOK settings screen for Anthropic API key
  - [ ] PAT flow: paste → Keychain → `Authorization: Bearer pat_…` (M4, reuses KeychainService)
  - [x] First two templates: presentation prep, research notes

## NU integration

- [ ] Wait for [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330) to merge
- [ ] Mint a PAT via Django shell (the "Connected Apps" console UI is post-merge work on the NU side)
- [ ] Use base URL `https://nbhd-django-westus2.victoriousocean-5cdd2683.westus2.azurecontainerapps.io` for dev; switch to `neighborhoodunited.org` once the custom domain is live
- [ ] Always include `"test_mode": true` on sessions pushed from dev builds
- [ ] Do not push real session data until the "Connected Apps" UI and the assistant-runtime tool are both live on NU — otherwise data lands but the assistant can't use it

## Leftover Clicky code to remove or replace

Files that still exist from Clicky's pipeline and aren't needed for YardTalk v1:

- [ ] `AssemblyAIStreamingTranscriptionProvider.swift` — cloud STT replaced by FluidAudio; remove
- [ ] `OpenAIAudioTranscriptionProvider.swift` — not used; remove
- [ ] `OpenAIAPI.swift` — not used; remove
- [ ] `ElevenLabsTTSClient.swift` — TTS not planned for v1; remove
- [ ] `ElementLocationDetector.swift` — cursor-pointing pipeline; remove or defer
- [ ] `CompanionResponseOverlay.swift` — response overlay from Q&A mode; remove or defer
- [ ] `CompanionScreenCaptureUtility.swift` — screenshot capture; may be repurposed for video clip capture
- [ ] `AppleSpeechTranscriptionProvider.swift` — system STT fallback; remove once FluidAudio is in
- [ ] `BuddyAudioConversionSupport.swift` — audio format conversion for AssemblyAI; review if needed for FluidAudio
- [ ] `BuddyDictationManager.swift` — dictation pipeline; will need rewrite for session recording
- [ ] `BuddyTranscriptionProvider.swift` — transcription protocol; update for FluidAudio
- [x] `ClaudeAPI.swift` — adapted for BYOK synthesis (direct Anthropic API calls with user-supplied key)
- [ ] `steve.jpg`, `codex-add-project.png` — Clicky assets; remove
- [ ] `enter.mp3`, `eshop.mp3` — Clicky sound effects; decide if YardTalk needs sounds
- [ ] `ff.mp3` — onboarding music; remove or replace

## Next steps

1. ~~Complete the Xcode-side renames~~ ✓
2. **Remove PostHog SPM package** and dead Clicky files listed above
3. ~~Add FluidAudio~~ ✓
4. ~~Build the project model~~ ✓
5. ~~Build session recording~~ ✓ (toggle-hotkey, display selection, markers, timeline)
6. ~~Build synthesis pipeline~~ ✓ (BYOK, two templates, synthesis UI)
7. **Build review/edit dialog** (M3) — edit summary/accomplishments/blockers/next_steps before upload
8. **Build NU PAT flow** (M4) — reuses KeychainService, settings screen gets a second field
9. **Build upload + NU integration** (M5) — three-way dialog, `POST /api/v1/sessions/`, idempotency, test_mode
10. **Build outbox** (M6) — queued/failed uploads with manual retry

## Reference

- Original Clicky architecture and conventions: git history before the rebrand commit
- Upstream: [farzaa/clicky](https://github.com/farzaa/clicky) (kept as `upstream` remote)
- NU API contract: [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330)
