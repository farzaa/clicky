# Rebrand TODO

Tasks to complete the Clicky → YardTalk transition. Xcode-side tasks must be done **in the IDE** (not from the terminal) — `.pbxproj` and asset catalogs are too fragile to hand-edit.

## In Xcode

- [ ] Rename `leanring-buddy` directory and scheme → `yardtalk` (File → Rename; Xcode updates project references)
- [ ] Rename targets: `leanring-buddy` → `yardtalk`, `leanring-buddyTests` → `yardtalkTests`, `leanring-buddyUITests` → `yardtalkUITests`
- [ ] Set `CFBundleName` and `CFBundleDisplayName` → `YardTalk`
- [ ] Set `CFBundleIdentifier` (e.g. `com.yardtalk.app`). The Python YardTalk does not set a bundle ID in its `setup.py`, so no collision risk on this machine.
- [ ] Register `yardtalk://` URL scheme in `CFBundleURLTypes` (used for NU signed deep-links later)
- [ ] Replace app icon in `Assets.xcassets` (temporary placeholder is fine)
- [ ] Set signing team under Signing & Capabilities
- [ ] Update `appcast.xml` once Sparkle updates are wired

## Command-line safe

- [ ] Grep for `clicky`, `Clicky`, `CLICKY`, `farzaa`, `farzatv` across the codebase; update user-facing strings; leave attribution in README/LICENSE intact
- [ ] Decide fate of `ClickyAnalytics.swift` — port to your own analytics or stub out
- [ ] Remove PostHog dependency if analytics is out of scope for v1
- [ ] Replace `clicky-demo.gif` and `dmg-background.png` once YardTalk has its own look
- [ ] Update any functional URLs (worker endpoints, download links, feedback channels) — keep attribution links

## Cloudflare Worker (`worker/`)

Clicky's worker proxies AssemblyAI, ElevenLabs, and Claude. For YardTalk:

- [ ] **Delete AssemblyAI endpoint** — FluidAudio runs locally, no cloud STT needed
- [ ] **Delete ElevenLabs endpoint** — no TTS planned for v1
- [ ] **Keep Claude endpoint** (repurpose) — if API keys shouldn't ship in the binary, the worker is still the right proxy
- [ ] **No NU endpoint needed** — NU's PAT auth is designed for direct client calls

## Replace Clicky's core loop with YardTalk's

- [ ] Strip push-to-talk → AssemblyAI → Claude → ElevenLabs → cursor-pointing pipeline
- [ ] Add FluidAudio as a Swift Package dependency
- [ ] Build:
  - [ ] Project model + picker UI (menu bar dropdown)
  - [ ] Session mode with hotkey-held video capture (`SCStream` + `AVAssetWriter`)
  - [ ] Per-session timeline, persisted to `~/Library/Application Support/YardTalk/…`
  - [ ] End-of-session review/edit dialog
  - [ ] Synthesis pipeline → Claude → structured payload
  - [ ] Three-way upload dialog (upload now / queue / keep local or delete)
  - [ ] Outbox view for queued pushes
  - [ ] PAT flow: paste → Keychain → `Authorization: Bearer pat_…`
  - [ ] First two templates: presentation prep, research notes

## NU integration

- [ ] Wait for [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330) to merge
- [ ] Mint a PAT via Django shell (the "Connected Apps" console UI is post-merge work on the NU side)
- [ ] Use base URL `https://nbhd-django-westus2.victoriousocean-5cdd2683.westus2.azurecontainerapps.io` for dev; switch to `neighborhoodunited.org` once the custom domain is live
- [ ] Always include `"test_mode": true` on sessions pushed from dev builds
- [ ] Do not push real session data until the "Connected Apps" UI and the assistant-runtime tool are both live on NU — otherwise data lands but the assistant can't use it

## Reference

- Original Clicky architecture and conventions: git history before the rebrand commit
- Upstream: [farzaa/clicky](https://github.com/farzaa/clicky) (kept as `upstream` remote)
- NU API contract: [`performlikemj/nbhd-united#330`](https://github.com/performlikemj/nbhd-united/pull/330)
