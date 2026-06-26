# Spider Private Beta Runbook

This runbook defines the path from local-ready Spider to a private beta with
real users. Private beta is not public production. The goal is 3-5 observed
users, real login, real entitlement, real Worker, real DMG, and real Meta Ads
screen guidance.

## Beta Definition

Spider is beta-ready only when all of these are true:

- A tester can install a Developer ID notarized DMG on a clean Mac account.
- The app opens as a menu bar companion named Spider.
- Magic-link login works through the production Worker.
- Paid entitlement or trial access is enforced by the Worker before Vision or
  Realtime cost.
- The user can start with `Build my campaign from scratch`.
- Spider creates a campaign direction from the offer.
- Spider opens Meta Ads and guides setup from the current screen.
- Spider stops before Publish, spend, budget, billing, pause, delete, or any
  irreversible campaign action.
- Preflight and 72h Review are visibly locked or absent. They must not appear as
  available MVP actions.
- Screenshots, prompts, transcripts, model responses, emails, magic links, and
  session tokens do not appear in analytics, diagnostics, D1 audit rows, release
  logs, or support notes.

If any of these fail, call it local testing, not beta. Words are cheap; confused
testers are not.

## Phase 0: Local Technical Gate

Run from the repo root:

```bash
git status --short
cd worker && npm run check && cd ..
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO build
bash scripts/release_preflight.sh
bash scripts/worker_deploy_preflight.sh
```

Expected before real config:

- `npm run check` passes.
- Debug macOS build passes.
- `release_preflight.sh` fails only on real external placeholders.
- `worker_deploy_preflight.sh` fails only on real external placeholders.

Unexpected failures must be fixed before touching Cloudflare, Stripe, Resend,
Apple signing, or release publishing.

## Phase 1: Real Release Configuration

Create the local, gitignored release env file:

```bash
cp scripts/release.env.example scripts/release.env
```

Fill these values with real beta infrastructure:

- `SPIDER_APPCAST_URL`
- `SPIDER_WORKER_BASE_URL`
- `SPIDER_LOGIN_CONFIRM_URL`
- `SPIDER_STRIPE_SUCCESS_URL`
- `SPIDER_STRIPE_CANCEL_URL`
- `SPIDER_D1_DATABASE_ID`
- `SPIDER_RELEASE_REPO`
- `SPIDER_DEVELOPMENT_TEAM`

Validate without rewriting project files:

```bash
source scripts/release.env
SPIDER_CONFIGURE_DRY_RUN=1 bash scripts/configure_release.sh
```

Apply only after the dry run passes:

```bash
source scripts/release.env
bash scripts/configure_release.sh
```

Do not put API keys, webhook secrets, or private credentials in
`scripts/release.env`. It is for release-facing URLs and identifiers only.

## Phase 2: Worker Production Gate

Create and migrate D1:

```bash
cd worker
npx wrangler d1 create spider
npx wrangler d1 migrations apply DB --remote
cd ..
```

Set required Worker secrets:

```bash
cd worker
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put EMAIL_HASH_SECRET
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put MAGIC_LINK_FROM
npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_PRICE_ID
npx wrangler secret put STRIPE_WEBHOOK_SECRET
cd ..
```

Then run:

```bash
bash scripts/worker_deploy_preflight.sh
bash scripts/worker_remote_preflight.sh
cd worker && npm run dry-run && cd ..
```

Only deploy after these pass:

```bash
cd worker
npx wrangler deploy
cd ..
```

After deploy, manually smoke:

- `POST /auth/login/start` sends a real email.
- Browser confirm page opens `spider://auth/confirm`.
- App exchanges the magic token over HTTPS.
- Invalid tokens and extra query params fail closed.
- Unpaid users cannot call Vision or Realtime.
- Paid/trial users can call Vision and Realtime.

## Phase 3: Billing Gate

Stripe must prove entitlement behavior, not just show a pretty Checkout page.

Required tests:

- New unpaid user is blocked before screen capture AI.
- Checkout creates a Stripe subscription.
- Checkout completion does not grant entitlement by itself.
- `customer.subscription.*` webhook grants or revokes access.
- `invoice.paid` reconciles active subscription state.
- `invoice.payment_failed` reconciles non-active subscription state.
- Canceled subscriptions keep access only through the paid period.
- Active users are sent to Customer Portal, not duplicate Checkout.
- `past_due`, `unpaid`, expired `canceled`, and revoked sessions fail closed.

Do not invite testers until these are tested against Stripe test mode end to
end with the deployed Worker.

## Phase 4: macOS Distribution Gate

Required:

- Developer ID Application certificate in Keychain.
- Hardened Runtime enabled.
- Notary credentials stored with `notarytool`.
- Sparkle tools available.
- Real appcast URL configured.
- `SPIDER_RELEASE_REPO` set to the intended GitHub release repo.

Run a dry release first:

```bash
source scripts/release.env
SPIDER_DRY_RUN=1 ./scripts/release.sh 1.0 1
```

Real release only from a reviewed source state:

```bash
source scripts/release.env
./scripts/release.sh 1.0 1
```

Do not bypass clean-worktree checks unless you can name exactly why. Shipping
from a mystery diff is not velocity; it is debt with a download link.

## Phase 5: Clean Mac QA

Install the notarized DMG on a clean Mac user account.

System permission QA:

- First launch shows Spider as a menu bar app.
- Screen Recording request works.
- Accessibility request works.
- Microphone request works.
- ScreenCaptureKit captures the visible screen.
- Push-to-talk works while Safari, Finder, Xcode, and a browser are frontmost.
- Overlay text appears on the right screen.
- Pointer appears only when coordinates are valid.
- Revoked Screen Recording/Accessibility/Microphone permissions fail closed.

Account QA:

- Magic-link login works from email.
- Logout clears the session.
- Expired/revoked session is rejected.
- Unpaid user is blocked before AI cost.
- Active subscription enables guidance.
- Billing portal opens only Stripe-hosted URLs.

Privacy QA:

- No screenshot content in analytics.
- No transcript content in analytics.
- No prompt or model response in analytics.
- No email, magic link, or session token in diagnostics.
- D1 audit rows contain event metadata only.
- Release logs contain no secrets.

## Phase 6: Meta Ads Product QA

Run this with a real Meta Ads account where accidental publish/spend would not
hurt the business. Still, Spider must stop before publish.

Flow:

1. Open Spider.
2. Choose `Build my campaign from scratch`.
3. Enter offer, audience, ticket, country, language, budget, business goal,
   landing page, and experience level.
4. Generate campaign direction.
5. Confirm objective recommendation and `what not to choose`.
6. Open Meta Ads from Spider.
7. Start Guided Setup.
8. Confirm Spider points or explains the current visible step.
9. Confirm Spider recommends the right campaign objective for the mission.
10. Confirm Spider warns before budget, billing, or publish decisions.
11. Stop before Publish.
12. Stop before Publish and confirm Spider does not offer Preflight or 72h
    Review as available actions.
13. Publish manually only if the human chooses to outside Spider.

Pass criteria:

- The first AHA is campaign construction from the offer.
- Preflight and 72h Review remain locked, not hidden behind fake working CTAs.
- Spider never clicks, publishes, spends, changes budget, edits billing, pauses,
  or deletes a campaign.
- Official Rule and Spider Judgment remain visibly separate when policy or
  platform rules are involved.
- Decision Memory records why a recommendation was made.

## Phase 7: Beta Invite

Invite only after phases 0-6 pass.

Tester instructions should fit on one page:

- Install the DMG.
- Open Spider from the menu bar.
- Sign in by magic link.
- Complete billing or trial activation.
- Grant Screen Recording, Accessibility, and Microphone.
- Open Meta Ads.
- Start with `Build my campaign from scratch`.
- Stop before Publish. Any manual publishing decision happens outside Spider.

Use `docs/private-beta-tester-guide.md` as the tester-facing version. Do not
send this runbook to testers unless they are also helping with release QA.

Collect feedback on:

- Where setup became confusing.
- Whether Spider understood the visible Meta screen.
- Whether the campaign direction felt trustworthy.
- Whether Spider stopped before risky publish, budget, billing, pause, or delete actions.
- Whether the user understood that Spider never spends.

## Current Known Non-Code Blockers

The current checkout is expected to remain blocked for external beta until:

- real release URLs replace placeholder app/Worker config;
- real Cloudflare D1 id replaces the placeholder D1 id;
- required Wrangler secrets exist remotely;
- real Stripe test-mode product, price, portal, and webhook are configured;
- Resend/domain email delivery is configured;
- Developer ID signing and notarization are configured;
- a clean-Mac QA pass is recorded.
