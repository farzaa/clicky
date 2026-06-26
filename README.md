# Spider

Spider is a macOS menu bar companion for non-expert advertisers learning and operating paid ads. It watches the current screen, understands the user's Ad Mission, and gives the next concrete step through voice, overlay text, and optional visual pointing.

This repository started as a fork of Clicky. The product direction is different now: Spider is screen-first, paid-ads-first, and built around safe server-side OpenAI access.

Product thesis: Spider does not repeat Meta Ads. It audits ad platforms using official rules, independent playbooks, and the user's business context.

## Current Migration State

Implemented:

- App rebrand from Clicky-facing UI to Spider.
- Privacy-safe analytics shim. No screenshots, transcripts, prompts, responses, or emails are sent to analytics.
- DEBUG diagnostics are centralized in `SpiderDiagnostics`; raw `Error` values and localized error strings are not logged.
- OpenAI GPT Vision guide client through the Worker. The macOS app does not ship an OpenAI API key.
- Structured guide response with spoken text, display text, next step, context kind, optional pointing coordinate, and optional artifact.
- Local `AdMission` JSON store in Application Support.
- Ad Mission reset from the panel. Reset clears local mission artifacts, decision memory, and in-memory conversation context without touching login, billing, or permissions.
- Meta Ads knowledge/playbook v1 under `worker/knowledge`, plus the product architecture spec under `docs/ads-product-architecture.md`. Preflight and 72h Review knowledge can exist for later, but those features are locked in the current MVP.
- Cloudflare Worker routes for magic link auth, entitlement checks, OpenAI Vision, OpenAI Realtime client secrets, Stripe Checkout, Stripe Portal, and Stripe webhooks.
- D1 migrations for users, sessions, magic links, usage counters, Stripe webhook dedupe, subscription state, and privacy-safe audit events.
- Worker audit events for login, checkout, billing portal, Vision, and Realtime requests. Audit rows never include screenshots, transcripts, prompts, emails, or model responses.
- Scheduled Worker cleanup prunes expired magic links, expired/revoked sessions, old quota counters, old audit rows, and processed Stripe webhook records.
- User emails are stored only as server-keyed HMAC hashes. A plain SHA-256 email hash is not acceptable for production because it is too easy to reverse with common address lists.
- Stripe webhook signature verification with timestamp tolerance and duplicate-event handling after entitlement processing.
- Stripe webhook events are reserved before processing, marked after success, and retried safely after processing failures.
- Stripe subscription state tracks customer id, subscription id, subscription status, current period end, and cancel-at-period-end. Canceled subscriptions keep access only through the paid period.
- Stripe Checkout completion only links customer/subscription ids. Entitlement is granted or revoked from `customer.subscription.*` status events, not from Checkout alone.
- Stripe invoice events reconcile subscription state by fetching the current Stripe subscription before changing access, covering paid renewals and failed payments without trusting invoice shape alone.
- Stripe Checkout is blocked for users who already have effective active/trial access, including canceled subscriptions still inside the paid period. Active users should manage billing through the Stripe Customer Portal.
- Effective access is derived from Stripe `subscription_status` whenever it exists. Stored `entitlement_status` is a fallback for accounts without Stripe state; it must not override `past_due`, `unpaid`, expired `canceled`, or other non-active subscription states.
- Sanitized Worker error responses for unexpected failures, with bad client JSON returning 400 and malformed upstream guide JSON returning 502.
- Screen mentor prompt now includes explicit safety boundaries for credentials, API keys, Meta Ads billing/payment/account surfaces, customer data, banking, tax, and irreversible campaign actions.
- Keychain-backed Worker session token storage.
- Magic-link login client for start/status/confirm flows.
- The macOS app normalizes and validates login email addresses before calling the Worker. The login form uses the same validator before enabling submit; the Worker still owns final auth validation.
- `spider://auth/confirm` deep link handling for magic-link completion. The app exchanges the short-lived magic token for a session token over HTTPS; long-lived session tokens are not delivered through browser URLs.
- Worker sessions are bound to a validated, hashed `X-Spider-Device-ID`. The raw device id is bounded, ASCII-only, and never stored; rate limits and sessions use only its hash. The browser bridge never creates a session; only the app can exchange a magic token for a device-bound session token. Legacy sessions without a device hash are revoked by migration and rejected by auth.
- The macOS app normalizes its Keychain device id as a UUID before sending it to the Worker, and regenerates it if the stored value is invalid.
- The macOS app stores Worker session tokens and the stable device id in non-syncing Keychain items available only while the device is unlocked.
- The macOS app validates magic-link tokens before calling `/auth/login/confirm`, so malformed deep links fail locally without touching the Worker.
- Worker validates bearer session token shape before hashing or touching D1. Malformed tokens get the same sanitized invalid-session response as expired tokens.
- The macOS app validates Worker session tokens before saving or reusing them, so malformed Keychain values are discarded instead of being sent forever.
- Worker browser bridge for magic links opened in a browser: HTML responses can forward valid one-time tokens into the Spider app without consuming the token in the browser.
- Browser bridge HTML uses no-store, no-referrer, nosniff, no inline JavaScript, and a restrictive Content Security Policy.
- Worker runtime validation rejects production magic-link and billing redirect URLs that are not HTTPS.
- Worker validates magic-link request bodies and production login URLs before writing rate counters, users, links, or audit rows.
- Worker validates magic-link token shape before hashing or touching D1, including browser bridge requests.
- Worker rate-limits magic-link confirmation before querying `magic_links`; app confirmation uses the hashed device id, while browser bridge confirmation uses Cloudflare's trusted client IP.
- Worker invalidates previous active magic links only after a new login email is accepted for delivery. If email delivery fails, the undelivered new link is consumed and older links are preserved.
- The macOS app validates `SpiderWorkerBaseURL` as a clean origin URL. Production requires HTTPS; local development is the only place where `http://localhost` style URLs are accepted.
- Worker validates OpenAI server configuration before AI rate counters, user quota, audit rows, or upstream calls.
- OpenAI upstream requests include a stable safety identifier derived from the server-side user hash. The identifier is not an email, transcript, prompt, screenshot, or artifact content.
- Vision and Realtime model choices are server-controlled Worker configuration. The macOS app must not expose or send model overrides.
- Worker validates structured GPT Vision guide responses before app delivery, including text caps, context kind, paid-ads decision fields, persisted artifacts, Ad Mission updates, and safe fallback for bad point coordinates.
- macOS Worker clients enforce request/response size limits before upload/decode so oversized screenshots or server responses fail safely.
- macOS guide responses and local Ad Mission artifacts are sanitized before UI use or persistence.
- Worker vision requests validate transcript length, screenshot count, image MIME type, base64 shape, and dimensions before quota/audit/OpenAI calls.
- Worker quota and rate counters use atomic D1 upserts with `RETURNING`, not race-prone read-before-increment checks.
- Worker bindings are generated with `wrangler types`, Worker checks run TypeScript in strict mode, and Stripe webhook signatures use Web Crypto timing-safe equality.
- Worker failures are mapped by status code in the macOS app. UI copy is app-owned and does not display raw Worker error descriptions.
- Client-side entitlement state that blocks screen AI before capture when the user is logged out or unpaid.
- Account-first beta flow in the panel: sign in and payment gate come before macOS screen/mic permissions.
- Login, Checkout, Billing Portal, and Logout actions expose in-flight state in the macOS UI so repeated clicks do not create duplicate auth, Stripe, or session-revocation requests.
- Guidance, hotkey, and onboarding demo paths check account and permissions before attempting screen capture.
- Release builds ignore `SpiderDevelopmentSessionToken`; development tokens work only in `DEBUG`.
- Development session tokens and injected Worker tokens are validated before use, so Vision and Realtime clients do not send malformed bearer tokens.
- Feedback email config is validated and converted to a `mailto:` URL through URL components, not string interpolation.
- Stripe Checkout and Customer Portal clients from the macOS panel.
- Stripe Checkout and Customer Portal URLs returned by the Worker must be HTTPS URLs without embedded credentials before the macOS app opens them. The Worker and the macOS app both pin returned Stripe sessions to the expected Stripe hosts and path shapes.
- OpenAI Realtime WebSocket speech playback from Spider guidance text, with local system voice fallback.
- OpenAI Realtime push-to-talk transcription provider for spoken user intent, with Apple Speech as emergency fallback.
- Spider release script for Developer ID archive, notarized DMG, Sparkle appcast generation, and GitHub Release publishing.
- Release preflight script that blocks public builds with placeholder bundle IDs, example URLs, stale Clicky release endpoints, or obvious committed secrets.
- App Sandbox is not silently waived. The current paid-beta exception is documented in `SPIDER_SECURITY_RELEASE_DECISIONS.md` with compensating controls and required stable-release review.
- Clean Spider `appcast.xml` scaffold. Historical Clicky/makesomething release items were removed.
- Legacy Clicky demo media, makesomething image assets, compatibility-only disabled providers, and unused overlay/detector files have been removed from the product tree.
- Legacy Anthropic, AssemblyAI, ElevenLabs, and direct OpenAI audio upload paths are removed from the product path. Screen guidance belongs to `OpenAIVisionGuideClient`; voice belongs to OpenAI Realtime through the Worker.

Locked or still in progress:

- Production polish for login and billing UI.
- Full-duplex Realtime conversation polish. The current product path is still push-to-talk into the visual guide.
- Preflight Audit and 72h Review are locked future features. They are not part
  of the current MVP.
- Production Stripe, Resend, Cloudflare D1 IDs, Apple signing identities, real bundle identifier, real appcast hosting URL, and first notarized DMG validation on a clean Mac.

## Architecture

- App: macOS SwiftUI/AppKit menu bar app.
- Screen capture: ScreenCaptureKit, multi-monitor.
- Guidance: OpenAI Responses API with GPT Vision through `POST /vision/guide`.
- Voice: OpenAI Realtime through Worker-issued ephemeral client secrets for both push-to-talk transcription and spoken playback. Local Apple/system speech is fallback only.
- Backend: Cloudflare Worker, D1, Stripe, Resend.
- Storage: local Ad Mission artifacts and decision memory in `Application Support/Spider/AdMission.json`.
- Privacy: screenshots and transcripts are request payloads only; they are not stored in D1 or analytics.
- Retention: operational rows are kept only as long as needed for auth, quota, entitlement, audit, and webhook retry safety.
- Local identity: session token and stable device identifier live in Keychain. Email is not persisted by the macOS app.

## Worker Routes

- `POST /auth/login/start`
- `GET /auth/login/confirm`
- `GET /auth/login/status`
- `POST /auth/logout`
- `POST /vision/guide`
- `POST /realtime/client-secret`
- `POST /billing/checkout`
- `POST /billing/portal`
- `POST /stripe/webhook`

## Worker Setup

```bash
cd worker
npm install
```

Create the D1 database, then materialize the production release config with
`scripts/configure_release.sh`. Do not hand-edit fake release values into the
app and hope everyone remembers to fix them later.

```bash
npx wrangler d1 create spider
npx wrangler d1 migrations apply spider
```

```bash
SPIDER_APPCAST_URL="https://<release-host>/spider/appcast.xml" \
SPIDER_WORKER_BASE_URL="https://<api-host>" \
SPIDER_LOGIN_CONFIRM_URL="https://<api-host>/auth/login/confirm" \
SPIDER_STRIPE_SUCCESS_URL="https://<app-host>/account" \
SPIDER_STRIPE_CANCEL_URL="https://<app-host>/account" \
SPIDER_D1_DATABASE_ID="<cloudflare-d1-database-uuid>" \
bash scripts/configure_release.sh
```

Set production secrets through Wrangler:

```bash
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put EMAIL_HASH_SECRET
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put MAGIC_LINK_FROM
npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_PRICE_ID
npx wrangler secret put STRIPE_WEBHOOK_SECRET
```

`ALLOWED_WEB_ORIGINS` should stay empty unless a browser-based surface calls the
Worker directly. If that happens, set a comma-separated allowlist of exact
production origins such as `https://<app-host>`. Do not use wildcard CORS.
At runtime the Worker ignores wildcard, non-HTTPS, malformed, and path-bearing
origin entries before echoing any CORS header.

Run locally:

```bash
cd worker
npx wrangler dev
```

Run Worker checks without calling OpenAI, Stripe, or Resend:

```bash
cd worker
npm run check
```

Run the deploy-facing Worker gate from the repo root:

```bash
bash scripts/worker_deploy_preflight.sh
```

This checks release URLs, D1 database id shape, migration presence/order,
required secret documentation, and Worker package scripts. It does not call
Cloudflare, which keeps it useful in CI and on machines without Wrangler auth.

When Wrangler is authenticated, run the remote gate:

```bash
bash scripts/worker_remote_preflight.sh
```

That verifies Cloudflare auth, remote secret names, remote D1 unapplied
migrations, and a strict deploy dry run. It never prints secret values and it
does not apply migrations or deploy the Worker. If it reports unapplied
migrations, apply them deliberately with Wrangler after reviewing the SQL.
`scripts/release.sh` runs this remote gate again before archive/export, because
a notarized DMG pointed at a broken Worker is not a release. It is a support
ticket wearing a nice icon.

`scripts/release_preflight.sh` runs the Worker typecheck and smoke test by
default. Skipping it is allowed only for quick local config checks, not for beta
release approval.

Dry-run the Worker bundle before deploy:

```bash
cd worker
npm run dry-run
```

Deploy only after the preflight and dry run are clean:

```bash
cd worker
npx wrangler deploy
```

## macOS App Setup

Open the project in Xcode:

```bash
open leanring-buddy.xcodeproj
```

Use the `leanring-buddy` scheme. The scheme name is legacy; the product name is Spider.

Do not run `xcodebuild` from the terminal for normal app work. This project depends on macOS TCC permissions for Screen Recording, Accessibility, Microphone, and ScreenCaptureKit. Running builds from different terminal contexts can burn time by forcing permission resets.

Runtime configuration lives in `leanring-buddy/Info.plist`:

- `SpiderWorkerBaseURL`
- `SpiderFeedbackEmail` optional; when absent, the feedback mail button is hidden.
- `SpiderDevelopmentSessionToken`
- `VoiceTranscriptionProvider`

For local development before the login UI is complete, set `SpiderDevelopmentSessionToken` to a valid Worker session token.

The app registers the `spider://` URL scheme. Production email links should use
the HTTPS Worker confirm route, which then opens the app through the deep link:

```toml
APP_LOGIN_CONFIRM_URL = "https://<api-host>/auth/login/confirm"
APP_LOGIN_DEEP_LINK_URL = "spider://auth/confirm"
```

Browser requests receive a no-store page that opens `APP_LOGIN_DEEP_LINK_URL`;
the app still performs the actual token exchange. Do not send `spider://`
directly in production email.

## Key Files

- `leanring-buddy/CompanionManager.swift`: main app state machine, Ad Mission state, decision memory, and screen guide flow.
- `leanring-buddy/OpenAIAPI.swift`: Spider guide types, Ad Mission store, and Worker vision client.
- `leanring-buddy/SpiderAuthClient.swift`: Worker magic-link auth client.
- `leanring-buddy/SpiderSessionStore.swift`: Keychain-backed session token store.
- `leanring-buddy/OpenAIRealtimeVoiceClient.swift`: OpenAI Realtime client-secret, WebSocket speech, and PCM playback.
- `leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift`: Realtime push-to-talk transcription provider.
- `leanring-buddy/SpiderAnalytics.swift`: privacy-safe analytics shim.
- `leanring-buddy/OverlayWindow.swift`: cursor overlay, response bubble, and pointing animation.
- `leanring-buddy/CompanionScreenCaptureUtility.swift`: multi-monitor screenshots.
- `worker/src/index.ts`: auth, quota, OpenAI, Stripe, and Resend Worker routes.
- `worker/knowledge/*.json`: Meta Ads official-rule/playbook objects used by the guide contract.
- `docs/ads-product-architecture.md`: product architecture and safety contract for the paid-ads pivot.
- `docs/private-beta-runbook.md`: phase-by-phase private beta gate for real users, deployed Worker, billing, notarized DMG, and Meta Ads QA.
- `docs/private-beta-tester-guide.md`: one-page tester-facing guide for installing Spider, granting permissions, starting Meta Ads Guided Setup, and reporting unsafe behavior.
- `worker/tests/smoke-worker.mjs`: local Worker smoke tests for CORS, auth gating, unpaid AI blocking before cost/audit, quota exhaustion, vision payload rejection, Stripe checkout/subscription entitlement rules, deep links, and retention cleanup.
- `worker/migrations/0001_spider_core.sql`: D1 schema.
- `worker/migrations/0002_subscription_state.sql`: Stripe subscription state fields.
- `worker/migrations/0003_stripe_event_processing.sql`: Stripe webhook processing state.
- `worker/migrations/0004_session_device_binding.sql`: device-bound sessions.
- `worker/migrations/0005_operational_retention_indexes.sql`: D1 indexes for scheduled retention cleanup.
- `scripts/release.sh`: manual Spider release pipeline for Developer ID export, notarized DMG, Sparkle appcast, and GitHub Release publishing.
- `scripts/release_preflight.sh`: safe release configuration gate that does not invoke Xcode.
- `scripts/worker_deploy_preflight.sh`: local Worker deployment contract for config, secrets, migrations, and package scripts.
- `scripts/worker_remote_preflight.sh`: authenticated Cloudflare read-only Worker preflight for remote secrets, D1 migration status, and strict deploy dry run.
- `scripts/configure_release.sh`: validates and materializes production app/Worker release config.
- `scripts/README.md`: release setup and public beta checklist.
- `SPIDER_SECURITY_RELEASE_DECISIONS.md`: security exceptions that must stay explicit for release.

## Security Rules

- Do not put OpenAI, Stripe, Resend, or other production secrets in the macOS app.
- Do not log screenshots, transcripts, prompts, model responses, magic links, session tokens, or emails.
- Do not log raw `Error` values or `localizedDescription`; use `SpiderDiagnostics` with static messages and numeric counts/statuses only.
- Do not persist screenshots.
- Do not add analytics SDKs that can receive user content.
- Entitlement and quota checks belong on the Worker, not in the client.
- Rate limits use `CF-Connecting-IP` and hashed device ids. Do not trust client-supplied forwarding headers such as `x-forwarded-for`.
