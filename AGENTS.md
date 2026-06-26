# Spider - Agent Instructions

This file is the operational contract for AI coding agents working in this repo. `CLAUDE.md` is a symlink to this file.

## Product

Spider is a macOS menu bar companion for non-expert advertisers learning and
operating paid ads. It is not a campaign automation agent. It acts as a
screen-first independent instructor and auditor: it looks at the user's current
screen, understands the Ad Mission, separates official platform rules from
Spider judgment, and gives one concrete next step.

The MVP is Meta Ads first-step Guided Setup: turn the user's offer into a
campaign direction, open Meta Ads, and guide the visible setup screen. Preflight
Audit and 72h Review are locked future features, not available in the current
MVP. V2 automates the first-step Guided Setup loop only; it does not add
publishing, spend, budget, billing, pause, delete, Preflight, or 72h Review
automation.

Product thesis: Spider does not repeat Meta Ads. It audits ad platforms using
official rules, independent playbooks, and the user's business context.

## Architecture

- App type: macOS menu bar-only app, no Dock icon, custom `NSPanel` control panel, transparent overlay panel.
- UI stack: SwiftUI with narrow AppKit bridges where macOS requires it.
- Screen capture: ScreenCaptureKit, multi-monitor.
- Guidance: OpenAI Responses API with GPT Vision through the authenticated Cloudflare Worker.
- Voice: OpenAI Realtime through Worker-issued ephemeral client secrets. Push-to-talk transcription and speech playback over WebSocket exist; the remaining work is full-duplex polish. Do not bring back ElevenLabs.
- Auth and billing: Cloudflare Worker, D1, magic link sessions, Stripe subscription entitlement.
- Email: Resend from the Worker.
- Local storage: `AdMission` JSON in Application Support.
- Analytics: privacy-safe local shim only.

## Security Rules

Security beats convenience in this repo.

- The macOS app must not contain production OpenAI, Stripe, Resend, Anthropic, AssemblyAI, or ElevenLabs keys.
- Screenshots, transcripts, prompts, model responses, emails, magic links, and session tokens must not be sent to analytics.
- Screenshots must not be persisted.
- Email must not be persisted in UserDefaults. The session token and stable device identifier belong in Keychain.
- User content must not be logged in Worker logs.
- Raw `Error` values and `localizedDescription` must not be logged by the macOS app. Use `SpiderDiagnostics` with static messages and numeric counts/statuses only.
- D1 audit rows are allowed only for coarse event names tied to user IDs. Never add screenshots, transcripts, prompts, model responses, emails, magic links, or tokens to audit rows.
- Entitlement and quota checks must happen on the Worker.
- Session tokens belong in Keychain when the login UI is wired.
- If a change makes data exposure easier, do not ship it.
- Spider never publishes ads, changes budget, edits billing, deletes campaigns,
  pauses campaigns automatically, guarantees policy approval, or guarantees
  performance. The user clicks. Spider never spends.

## Current Provider Policy

- OpenAI GPT Vision is the only primary screen guide provider.
- OpenAI Realtime is the target voice provider.
- Apple Speech is acceptable as a local development fallback for push-to-talk transcription.
- Anthropic, AssemblyAI, ElevenLabs, and direct client-side OpenAI audio upload are disabled legacy paths.
- Do not add PostHog or any analytics SDK that can receive user content.

## Key Files

| File | Purpose |
| --- | --- |
| `leanring_buddyApp.swift` | Menu bar app entry point. |
| `CompanionManager.swift` | Main state machine for permissions, push-to-talk, screenshots, guide requests, overlay, local speech fallback, Ad Mission state, and decision memory. |
| `CompanionPanelView.swift` | Menu bar panel UI. |
| `OpenAIAPI.swift` | Spider guide DTOs and structured response contracts. |
| `SpiderGuideResponseSanitization.swift` | Local guide-response sanitization before UI use or persistence. |
| `OpenAIVisionGuideClient.swift` | Worker vision guide HTTP client and request/response size gates. |
| `GuidedSetupPromptContext.swift` | Privacy-safe serialization of guided setup metadata for guide prompts. |
| `SpiderAuthClient.swift` | Worker magic-link auth client. |
| `SpiderSessionStore.swift` | Keychain-backed Worker session token store. |
| `OpenAIRealtimeVoiceClient.swift` | OpenAI Realtime client-secret, WebSocket speech, and PCM playback. |
| `OpenAIRealtimeTranscriptionProvider.swift` | Realtime push-to-talk transcription provider. |
| `CompanionGuidePipelineClock.swift` | Shared latency timing for the screen-guidance request pipeline. |
| `CompanionPreDotVerificationCoordinator.swift` | Pre-dot verification boundary between CompanionManager and guided setup session state. |
| `CompanionGuidePointTelemetryRecorder.swift` | Companion-level accepted/rejected/suppressed guide-point telemetry boundary. |
| `CompanionGuidePointSensorFusionRunner.swift` | Sensor-fusion execution and telemetry boundary for gate-approved guide points. |
| `GuidedSetupOutcomeDecisionBuilder.swift` | Pure outcome-decision builder for previously accepted guided-setup points. |
| `SpiderAnalytics.swift` | Privacy-safe analytics shim. |
| `SpiderGroundingAnalytics.swift` | Privacy-safe typed grounding telemetry event APIs. |
| `GroundingTelemetryMetadata.swift` | Privacy-safe grounding telemetry metadata contracts and builders. |
| `SpiderGroundingTelemetryPayloadBuilder.swift` | Allowlisted grounding telemetry payload serialization. |
| `SpiderGroundingTelemetryEmitter.swift` | Local grounding telemetry opt-in gate, app-version sanitization, and metric serialization. |
| `GroundingSensorFusion.swift` | Vision-first local dot confirmation orchestrator. |
| `GroundingSensorFusionSignalCollector.swift` | Privacy-safe local signal collection for Vision-selected guide points. |
| `GroundingSensorFusionContracts.swift` | Typed sensor-fusion contracts for dot decisions, evidence, policy, and latency. |
| `GroundingSensorFusionTiming.swift` | Sensor timing helpers and latency cutoff handling. |
| `OverlayWindow.swift` | Transparent overlay, cursor animation, response bubble, and pointing behavior. |
| `CompanionScreenCaptureUtility.swift` | Multi-monitor ScreenCaptureKit capture. |
| `scripts/release.sh` | Manual release-only pipeline for Developer ID export, notarized DMG, Sparkle appcast, and GitHub Release publishing. |
| `scripts/release_preflight.sh` | Safe release configuration gate. It does not invoke Xcode. |
| `BuddyTranscriptionProvider.swift` | Provider factory. Defaults to OpenAI Realtime with Apple Speech fallback. |
| `worker/src/index.ts` | Cloudflare Worker routes for auth, entitlement, quota, OpenAI, Stripe, and Resend. |
| `worker/migrations/0001_spider_core.sql` | D1 schema. |
| `worker/migrations/0002_subscription_state.sql` | Stripe subscription state fields. |

## Build And Run

Open in Xcode:

```bash
open leanring-buddy.xcodeproj
```

Use the `leanring-buddy` scheme. The scheme name is legacy. The built product is Spider.

Do not run `xcodebuild` from the terminal as routine workflow. This app depends on macOS TCC permissions, and terminal-driven builds can force permission churn for Screen Recording, Accessibility, Microphone, and ScreenCaptureKit.

Safe non-Xcode checks:

```bash
plutil -lint leanring-buddy/Info.plist
bash scripts/release_preflight.sh
cd worker && npx wrangler deploy --dry-run --outdir /tmp/spider-worker-dry-run
```

`scripts/release.sh` intentionally uses `xcodebuild` because release packaging has to archive/export the app. Do not run it as a routine coding check. Use it only from a clean release commit with `SPIDER_RELEASE_REPO` set.

## Worker

Routes:

- `POST /auth/login/start`
- `GET /auth/login/confirm`
- `GET /auth/login/status`
- `POST /auth/logout`
- `POST /vision/guide`
- `POST /realtime/client-secret`
- `POST /billing/checkout`
- `POST /billing/portal`
- `POST /stripe/webhook`

Magic-link safety:

- Prefer `spider://auth/confirm?token=...` for direct app login links.
- If using an HTTPS Worker login link for browser compatibility, the Worker may return a no-store bridge page that opens `spider://auth/confirm`.
- Do not put long-lived session tokens in browser URLs. The app must exchange the short-lived magic token for a session token over HTTPS and then store it in Keychain.

Secrets must be set with Wrangler:

```bash
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put MAGIC_LINK_FROM
npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_PRICE_ID
npx wrangler secret put STRIPE_WEBHOOK_SECRET
```

## Coding Standards

- Prefer clear, boring, senior code over clever shortcuts.
- Keep user-facing behavior screen-first. Screenshot context is core, not decoration.
- Keep edits close to the requested product direction.
- Use existing SwiftUI/AppKit patterns in this repo before inventing new ones.
- Use `@MainActor` for UI state.
- Use async/await for network and long-running work.
- Add comments only when they explain a non-obvious reason.
- Do not rename the project folder or the `leanring-buddy` scheme unless explicitly asked.
- Do not revive legacy providers to get a quick demo working.

## Sprint Direction

The migration plan is eight one-week sprints:

1. Base Spider, privacy, and legacy provider removal.
2. Public backend with auth, quota, and secure OpenAI access.
3. GPT Vision screen guide.
4. Overlay and pointing as the main product surface.
5. OpenAI Realtime voice.
6. Product workspace and copyable artifacts.
7. Paid beta with Stripe entitlement.
8. DMG packaging, hardening, and public beta.

When continuing implementation, prefer finishing a secure vertical slice over scattering partial features across every sprint.
