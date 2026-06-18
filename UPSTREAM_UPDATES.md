# Pulling Upstream Updates Safely

This fork (`sanhe/clicky`) tracks the original project but **removes its
telemetry and supply-chain risks**. We build and install **from the `my-main`
branch**, not from the upstream Sparkle auto-updater.

This document explains how to pull future changes from the original repo
**without re-introducing the issues we deliberately removed.**

---

## Branch model

| Branch | Role |
|--------|------|
| `main` | Clean mirror of upstream history. Used only as a merge base — **never installed from**. |
| `my-main` | **Our hardened branch. Build and install from this.** Contains all the security changes below. |

Upstream lineage: `farzaa/clicky` → (also pulls from `julianjear/makesomething-mac-app` release infra) → our fork `sanhe/clicky`.

---

## Hardening applied to `my-main` (the baseline to preserve)

Every upstream merge must **keep all of these in place**. If a merge reverts
any of them, re-apply it before building.

### 1. PostHog analytics — REMOVED ENTIRELY
The upstream app shipped the full voice transcript, the full AI response text,
and the user's email to PostHog (`us.i.posthog.com`). All of it is gone:
- Deleted `leanring-buddy/ClickyAnalytics.swift`.
- Removed `import PostHog`, every `ClickyAnalytics.*` call, and the
  `PostHogSDK.shared.identify(...)` call in `CompanionManager.swift`.
- Removed the `posthog-ios` Swift Package from `project.pbxproj` and
  `Package.resolved` (this also dropped its transitive `plcrashreporter` dep).

### 2. Sparkle auto-update — TRUST ANCHOR NEUTRALIZED
Upstream auto-update pointed at a **third party's** GitHub repo
(`julianjear/makesomething-mac-app`). We don't use Sparkle — we update via git.
- Removed `SUFeedURL` and `SUPublicEDKey` from `leanring-buddy/Info.plist`.
- Removed the Sparkle bootstrap code (`import Sparkle`,
  `SPUStandardUpdaterController`, `startSparkleUpdater()`) from
  `leanring_buddyApp.swift`.
- Repointed `scripts/release.sh` `GITHUB_REPO` to `sanhe/clicky`.
- The Sparkle Swift Package is left linked-but-unused (no code imports it, no
  feed URL). To remove it completely: Xcode → Project → Package Dependencies →
  delete `Sparkle`, then delete its `release.sh` signing steps.

### 3. Cloudflare Worker — OPTIONAL SHARED-SECRET AUTH
The proxy was open to anyone who learned its URL. Added an opt-in gate:
- `worker/src/index.ts` rejects requests with `401` unless the
  `x-proxy-secret` header matches the `PROXY_SHARED_SECRET` worker secret.
  **If the secret is unset, the proxy stays open (backward compatible).**
- The app sends `x-proxy-secret` from the `WorkerProxySecret` key in
  `Info.plist` (sent only when non-empty) — wired in `ClaudeAPI.swift`,
  `ElevenLabsTTSClient.swift`, and `AssemblyAIStreamingTranscriptionProvider.swift`.

To turn it on:
```bash
cd worker
npx wrangler secret put PROXY_SHARED_SECRET   # paste a long random string
```
Then put the **same** string in `leanring-buddy/Info.plist` under
`WorkerProxySecret` and rebuild.

### 4. Dead code — DELETED
- `leanring-buddy/OpenAIAPI.swift` (unused).
- `leanring-buddy/ElementLocationDetector.swift` (unused; it called
  `api.anthropic.com` directly with an embedded `x-api-key`, bypassing the proxy).

### 5. Unused entitlement — REMOVED
- Dropped `com.apple.security.device.camera` from
  `leanring-buddy/leanring-buddy.entitlements` (no camera code exists).

---

## How to pull an upstream update

```bash
# 1. Fetch the original project (no remote needed — fetch by URL)
git fetch https://github.com/farzaa/clicky main

# 2. Review exactly what changed BEFORE merging
git log --oneline HEAD..FETCH_HEAD
git diff --stat HEAD..FETCH_HEAD

# 3. Inspect the diff against the security-sensitive files (see checklist below)
git diff HEAD..FETCH_HEAD -- leanring-buddy/Info.plist \
  leanring-buddy/leanring-buddy.entitlements \
  worker/src/index.ts \
  "leanring-buddy/*.swift" \
  leanring-buddy.xcodeproj/project.pbxproj

# 4. Merge into my-main (resolve conflicts in favor of OUR hardening)
git switch my-main
git merge FETCH_HEAD

# 5. Re-run the verification checklist below. If anything regressed, fix it,
#    then commit.
```

---

## Post-merge verification checklist

Run this after every merge. All checks should pass before you build/install.

```bash
# A. PostHog must NOT come back (expect: NONE)
grep -rni 'posthog\|ClickyAnalytics' leanring-buddy/ \
  leanring-buddy.xcodeproj/project.pbxproj \
  leanring-buddy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# B. No third-party Sparkle feed in Info.plist (expect: NONE)
grep -n 'SUFeedURL\|SUPublicEDKey\|makesomething\|julianjear' leanring-buddy/Info.plist

# C. No Sparkle auto-updater being started (expect: NONE, or only commented)
grep -rn 'startSparkleUpdater\|SPUStandardUpdaterController' leanring-buddy/

# D. No hardcoded API keys / direct provider calls bypassing the worker
#    (expect: NONE — all provider traffic must go through the worker proxy)
grep -rni 'x-api-key\|xi-api-key\|sk-ant\|sk-\|api[_-]\?key.*=.*["'"'"'][A-Za-z0-9]\{20,\}' \
  leanring-buddy/ worker/src/

# E. Worker still has the shared-secret gate (expect: a match)
grep -n 'PROXY_SHARED_SECRET\|x-proxy-secret' worker/src/index.ts

# F. The worker base URL is still YOUR worker (or the placeholder),
#    never someone else's domain
grep -rn 'workers.dev' leanring-buddy/

# G. No unexpected network hosts. Review this list — every host must be one you
#    trust (your worker, api.openai.com, streaming.assemblyai.com, mux video,
#    submit-form.com). Anything new is a red flag.
grep -rEoh 'https?://[a-zA-Z0-9._-]+' leanring-buddy/*.swift | sort -u
```

### What each check defends against

| Check | Reintroduced risk it catches |
|-------|------------------------------|
| A | Telemetry of your transcripts / AI responses / email to PostHog |
| B | Auto-updates trusting a third party's repo / signing key |
| C | Silent download-and-run of remote code via Sparkle |
| D | Raw API keys shipped in the app, or providers called directly (bypassing the key-hiding proxy) |
| E | The worker becoming an open proxy that bills your API accounts |
| F | App pointed at someone else's proxy (exfiltration of your screen + voice) |
| G | A brand-new exfiltration endpoint slipped in upstream |

> **Note on what still leaves the device by design:** screenshots of all
> monitors + your voice transcript + the last 10 turns go to Claude via your
> worker; raw microphone audio streams to AssemblyAI; response text goes to
> ElevenLabs via your worker. The onboarding email is still POSTed to
> `submit-form.com` (FormSpark). If you want to drop that too, remove the
> FormSpark `Task { ... }` block in `CompanionManager.submitEmail(_:)`.

---

## Rule of thumb when resolving merge conflicts

If upstream re-adds analytics, a third-party update feed, an embedded API key,
or removes the worker auth — **take our side.** Upstream optimizes for the
original author's distribution and metrics; this fork optimizes for your
privacy and a self-controlled install.
