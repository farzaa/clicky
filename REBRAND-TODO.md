# Rebrand TODO

Tasks to complete the Clicky → YardTalk transition. Xcode-side tasks must be done **in the IDE** (not from the terminal) — `.pbxproj` and asset catalogs are fragile, and `xcodebuild` from the terminal invalidates TCC grants (see `CLAUDE.md`).

> Status as of the Developer ID release-prep pass: the rebrand itself is essentially complete. What remains is product work (M3–M6), NU integration, and a few cosmetic asset swaps.

## Rebrand — done ✓

- [x] Rename directory/scheme and targets → `yardtalk`, `yardtalkTests`, `yardtalkUITests`
- [x] `CFBundleName` / `CFBundleDisplayName` → `YardTalk` (build settings)
- [x] `PRODUCT_NAME` → `YardTalk`
- [x] `CFBundleIdentifier` → `com.yardtalk.app`
- [x] `INFOPLIST_KEY_NSScreenCaptureUsageDescription` rewritten (no longer the Clicky string)
- [x] Register `yardtalk://` URL scheme in `CFBundleURLTypes`
- [x] Remove PostHog SPM package (0 references remain in `.pbxproj`)
- [x] Replace app icon in `Assets.xcassets` → YardTalk logo (native rounded macOS icon, all sizes)
- [x] Set signing team → `263YH9X3BU` (Developer ID Application cert)
- [x] Rename `ClickyAnalytics.swift` → `Analytics.swift` (stubbed no-ops)
- [x] Remove the upstream `SUFeedURL` (it pointed at the original author's repo); Sparkle left dormant
- [x] Menu bar glyph → "YT" monogram (`MenuBarGlyph` asset), replacing Clicky's triangle (an island silhouette was tried first but read as a blob at 16px)
- [x] Grep/clean `clicky`/`farzaa` from Swift source (0 references remain; attribution kept in README/LICENSE)

### Leftover Clicky code/assets — removed ✓

- [x] `AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`, `OpenAIAPI.swift`, `ElevenLabsTTSClient.swift`, `ElementLocationDetector.swift`, `AppleSpeechTranscriptionProvider.swift`, `BuddyDictationManager.swift`, `BuddyTranscriptionProvider.swift`, `BuddyAudioConversionSupport.swift`, `CompanionResponseOverlay.swift`, `CompanionScreenCaptureUtility.swift`
- [x] `steve.jpg`, `codex-add-project.png`, `clicky-demo.gif`, `enter.mp3`, `eshop.mp3`, `ff.mp3` (removed from the repo; only stale copies under `build/` remain, which is gitignored)
- [x] `ClaudeAPI.swift` — adapted for BYOK synthesis (direct Anthropic calls, user key in Keychain)

## Rebrand — still pending

- [ ] Replace `dmg-background.png` — still Clicky's artwork (used by `scripts/make-dmg.sh`); swap before a public release
- [ ] **Auto-update decision**: Sparkle is linked but dormant (`startSparkleUpdater()` commented out in `YardTalkApp.swift`). Either wire it to a self-hosted appcast (generate EdDSA keys, host `appcast.xml`) or remove the dependency entirely. Until then, updates are manual DMG downloads.

## Distribution — done ✓

See `RELEASE.md` for the full release runbook.

- [x] Developer ID path chosen (non-sandboxed; required by the global hotkeys). Entitlements de-sandboxed to mic + camera under Hardened Runtime.
- [x] `Info.plist` cleaned (dropped AssemblyAI provider key, unused Speech permission, stranger's Sparkle feed; accurate usage strings; `LSApplicationCategoryType = productivity`)
- [x] `RELEASE.md` + `scripts/make-dmg.sh` (packages an exported `.app` into a notarized, stapled DMG without invoking `xcodebuild`)

## Product features

- [x] Project model + picker UI (menu bar dropdown)
- [x] Session mode: toggle-hotkey video capture (`SCStream` + `AVAssetWriter`, ⌃⌥D toggle, ⌃⌥M markers)
- [x] **Voice-only notes (⌃⌥V)** — mic-only `.m4a`, no screen capture; mutual exclusion with screen clips; `audioOnly` on `YardTalkClip` (with unit tests)
- [x] Display selection overlay (full-screen per-display on hotkey press)
- [x] Per-session timeline with clip expansion, deletion, QuickLook
- [x] Synthesis pipeline → Claude → structured payload (BYOK, direct API)
- [x] Synthesis UI: progress, summary preview, error+retry, manual synthesize
- [x] Keychain service for secure credential storage
- [x] BYOK settings screen for Anthropic API key
- [x] First two templates: presentation prep, research notes
- [ ] **M3** — end-of-session review/edit dialog (edit summary/accomplishments/blockers/next_steps before upload)
- [ ] **M4** — PAT flow: paste → Keychain → `Authorization: Bearer pat_…` (reuses KeychainService)
- [ ] **M5** — three-way upload dialog (upload now / queue / keep local or delete) + `POST /api/v1/sessions/create/`, idempotency, `test_mode`
- [ ] **M6** — outbox view for queued/failed pushes with manual retry

## Cloudflare Worker (`worker/`) — done ✓

- [x] Deleted AssemblyAI + ElevenLabs endpoints (FluidAudio is local; no TTS in v1)
- [x] Claude proxy dropped in favor of BYOK (optional proxy override retained in `ClaudeAPI`)
- [x] No NU endpoint needed (PAT auth is direct-client)

## NU integration

- [ ] Wait for [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330) to merge
- [ ] Mint a PAT via Django shell (Connected Apps console UI is post-merge work on NU)
- [ ] Dev base URL `https://nbhd-django-westus2.victoriousocean-5cdd2683.westus2.azurecontainerapps.io`; switch to `neighborhoodunited.org` once the custom domain is live
- [ ] Always send `"test_mode": true` from dev builds
- [ ] Do not push real session data until the Connected Apps UI and the assistant-runtime tool are both live on NU

## Reference

- Original Clicky architecture/conventions: git history before the rebrand commit
- Upstream: [farzaa/clicky](https://github.com/farzaa/clicky) (kept as `upstream` remote)
- NU API contract: [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330)
