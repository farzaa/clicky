# Releasing YardTalk

YardTalk ships as a **Developer ID-signed, notarized** direct download (DMG) —
**not** via the Mac App Store. The core UX (global hotkeys ⌃⌥D / ⌃⌥V / ⌃⌥M via a
system-wide key monitor) requires a non-sandboxed app, which the App Store
forbids. See `CLAUDE.md` and the `distribution_signing` memory for the why.

> **Never run `xcodebuild` from the terminal.** It invalidates YardTalk's TCC
> grants (Screen Recording, Microphone, Accessibility). Archive and export in
> Xcode; only the notarization/packaging steps run on the command line.

## One-time setup

1. **Developer ID Application certificate** — required for notarized distribution.
   Confirm it exists:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   # expect: Developer ID Application: Michael Jones (263YH9X3BU)
   ```
   If missing: Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage
   Certificates ▸ + ▸ Developer ID Application.

2. **Notary credentials** — store an app-specific password once so the DMG
   script can notarize non-interactively:
   ```bash
   # Create an app-specific password at appleid.apple.com first.
   xcrun notarytool store-credentials YardTalkNotary \
     --apple-id mj1@duck.com --team-id 263YH9X3BU
   # then, when releasing:  export NOTARY_PROFILE=YardTalkNotary
   ```

## Per-release checklist

### 1. Pre-flight (in the repo)
- [ ] Working tree clean; on the release branch.
- [ ] Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION` / build number) in
      the project's build settings if this is a new version.
- [ ] Run the tests in Xcode (**⌘U**) — must be green. (Do **not** `xcodebuild test`.)
- [ ] Smoke-test (**⌘R**): menu-bar glyph is the Jamaica silhouette; ⌃⌥D records
      a screen clip; ⌃⌥V records a voice note (mic indicator + "Recording voice
      note…"); ⌃⌥M drops a marker; a clip transcribes and appears in the session.

### 2. Archive & export (Xcode)
- [ ] Product ▸ **Archive** (Release).
- [ ] In the Organizer: **Distribute App ▸ Direct Distribution** (Developer ID).
- [ ] Let Xcode sign + notarize the archive, then **Export** the `.app`.
      (Xcode can notarize the app at this stage; the DMG is notarized separately
      below so the downloaded disk image itself is trusted.)

### 3. Package the DMG (terminal — safe)
```bash
export NOTARY_PROFILE=YardTalkNotary        # from one-time setup
scripts/make-dmg.sh /path/to/exported/YardTalk.app YardTalk-<version>.dmg
```
The script stages the app + an `/Applications` drop target, builds a compressed
DMG, then notarizes and staples it. Without `NOTARY_PROFILE` (or the
`NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_PASSWORD` trio) it builds the DMG but
skips notarization.

### 4. Verify the artifact
- [ ] `xcrun stapler validate YardTalk-<version>.dmg` → "The validate action worked!"
- [ ] `spctl -a -t open --context context:primary-signed -v YardTalk-<version>.dmg`
      → accepted.
- [ ] **Clean-Mac test** (or a fresh user account): mount, drag to Applications,
      launch. First launch should open without a Gatekeeper block. First hotkey
      prompts for Input Monitoring; first recording prompts for Screen Recording
      + Microphone.

### 5. Publish
- [ ] Tag the release: `git tag v<version> && git push --tags`.
- [ ] Upload `YardTalk-<version>.dmg` to the download location.
- [ ] (When auto-update is wired) regenerate the Sparkle appcast — see below.

## Notes

- **Auto-update is dormant.** Sparkle is linked but `startSparkleUpdater()` is
  commented out in `YardTalkApp.swift`, and the upstream feed URL was removed.
  Until a real appcast is hosted, users update by downloading a new DMG.
- **`dmg-background.png` is still Clicky's** artwork (tracked in `REBRAND-TODO.md`).
  Replace it before a public release if you want YardTalk's own DMG look.
- **Signing identity is your legal name.** Developer ID signs as
  "Michael Jones (263YH9X3BU)", visible via `codesign -dv` on the shipped app —
  inherent to an individual Apple Developer account, regardless of in-app
  branding. An Organization account would sign as the org instead.
