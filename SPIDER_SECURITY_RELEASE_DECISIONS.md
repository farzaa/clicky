# Spider Security Release Decisions

This file records security exceptions that affect public beta release readiness.
It is intentionally blunt: if a release needs a risky setting, the risk must be
named, bounded, and reviewed instead of hiding in an Xcode checkbox.

## App Sandbox

Decision: App Sandbox disabled for paid beta.

Current state:

- Xcode project sets `ENABLE_APP_SANDBOX = NO` for the Spider app target.
- `leanring-buddy/leanring-buddy.entitlements` keeps `com.apple.security.app-sandbox` set to `false`.
- Distribution target is Developer ID notarized DMG, not Mac App Store.

Why this exception exists:

- Spider is a screen-first companion and depends on ScreenCaptureKit.
- Push-to-talk depends on a global CGEvent tap so modifier-only shortcuts work while other apps are active.
- Window guidance and setup depend on Accessibility APIs such as `AXIsProcessTrusted`.
- The app uses microphone input, WebSocket Realtime audio, overlay windows, and menu bar panels.
- Enabling App Sandbox without a dedicated compatibility pass could silently break the core product path: screen capture, hotkey, pointing, and permission onboarding.

Required compensating controls:

- Hardened Runtime must stay enabled.
- Developer ID signing and notarization are required for public beta DMGs.
- The macOS app must not contain OpenAI, Stripe, Resend, Cloudflare, or webhook secrets.
- Screenshots, transcripts, prompts, model responses, emails, magic links, and session tokens must not be sent to analytics.
- Screenshots must stay request-scoped and in memory on the client unless the user explicitly creates an artifact.
- Worker access must require a valid session and paid entitlement before OpenAI cost is incurred.
- Session token and stable device id must stay in non-syncing Keychain items available only while the device is unlocked.
- Local project artifacts must stay under `Application Support/Spider` with owner-only permissions and capped file sizes.
- Release preflight must remain red while production URLs, D1 id, appcast URL, or release repo are placeholders.

Required beta QA before distribution:

- Install the notarized DMG on a clean Mac user account.
- Confirm first-run Screen Recording, Accessibility, Microphone, and ScreenCaptureKit permission flows.
- Confirm push-to-talk works while Cursor, Xcode, Safari, and Finder are frontmost.
- Confirm Spider can capture the active screen, receive GPT Vision guidance, and point only when coordinates are valid.
- Confirm logout, expired token, unpaid account, canceled subscription, and revoked permissions fail closed.
- Confirm no screenshot, transcript, prompt, model response, email, magic link, or session token appears in analytics, diagnostics, D1 audit rows, or release logs.

Required review before stable release:

- Re-test the app with App Sandbox enabled in a dedicated branch.
- Keep sandbox disabled only if a documented blocker remains for ScreenCaptureKit, CGEvent tap, Accessibility, or overlay behavior.
- If sandbox remains disabled after beta, add an explicit stable-release exception with test evidence and a narrower mitigation plan.
