# Release Scripts

## `release.sh` - Ship Spider for macOS

This script is for manual beta/release distribution only. It archives the app,
exports a Developer ID signed build, creates a DMG, notarizes it, signs the
Sparkle update payload, generates `appcast.xml`, and creates a GitHub Release.

Do not use this as a routine validation command. Spider requests screen and mic
permissions, and repeatedly launching build products from automation can make
macOS TCC state noisy. Use Xcode for normal app runs.

## Quick Start

For the full private beta sequence, use `docs/private-beta-runbook.md`. This
file documents the release scripts; the runbook defines the gate order for real
testers.

For beta setup, start from the local env template:

```bash
cp scripts/release.env.example scripts/release.env
```

Edit `scripts/release.env` with real values, then load it only in your shell:

```bash
source scripts/release.env
```

`scripts/release.env` is intentionally gitignored. It must not contain API
keys, webhook secrets, or private credentials; those still belong in Wrangler,
Keychain, GitHub, or Apple's notarization tooling.

```bash
SPIDER_APPCAST_URL="https://<release-host>/spider/appcast.xml" \
SPIDER_WORKER_BASE_URL="https://<api-host>" \
SPIDER_LOGIN_CONFIRM_URL="https://<api-host>/auth/login/confirm" \
SPIDER_STRIPE_SUCCESS_URL="https://<app-host>/account" \
SPIDER_STRIPE_CANCEL_URL="https://<app-host>/account" \
SPIDER_D1_DATABASE_ID="<cloudflare-d1-database-uuid>" \
bash scripts/configure_release.sh

SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh
```

The release repo is required. The old Clicky/makesomething repo is deliberately
not a default, because publishing a paid beta artifact to the wrong place would
be a beautiful little disaster.

`configure_release.sh` writes only release-facing configuration:

- `SUFeedURL` and `SpiderWorkerBaseURL` in `leanring-buddy/Info.plist`.
- `APP_LOGIN_CONFIRM_URL`, Stripe redirect URLs, and D1 `database_id` in `worker/wrangler.toml`.

The script rejects `example.com`, non-HTTPS URLs, Worker URLs that are not clean
origins, magic-link URLs that do not end at `/auth/login/confirm`, and D1 IDs
that are not UUID-shaped. No secrets belong in this script or in these files.

## Current Private Beta Blockers

On a fresh checkout, `bash scripts/release_preflight.sh` is expected to stay red
until real production configuration exists. These are external blockers, not
code placeholders to paper over:

- `SUFeedURL` in `leanring-buddy/Info.plist` must point to the hosted Sparkle
  `appcast.xml`.
- `SpiderWorkerBaseURL` in `leanring-buddy/Info.plist` must point to the
  production Worker origin.
- `APP_LOGIN_CONFIRM_URL`, `STRIPE_SUCCESS_URL`, `STRIPE_CANCEL_URL`, and
  `database_id` in `worker/wrangler.toml` must point to real production values.
- `SPIDER_RELEASE_REPO` must identify the GitHub repo that will receive beta
  DMG releases.

Validate the production values without rewriting files first:

```bash
source scripts/release.env
SPIDER_CONFIGURE_DRY_RUN=1 bash scripts/configure_release.sh
```

When the values are real, apply them deliberately:

```bash
source scripts/release.env
bash scripts/configure_release.sh
```

After that, set Worker secrets with Wrangler, run the local and remote Worker
preflights, then set `SPIDER_RELEASE_REPO` only when you are actually preparing
a signed beta artifact.

## Version Overrides

```bash
SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0
SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0 42
```

Without arguments, the script reads the latest GitHub release tag and bumps the
minor version. The build number defaults to the release count plus one. For real
public beta releases, pass the build number explicitly.

## Dry Run

```bash
SPIDER_RELEASE_REPO="owner/spider-mac-app" SPIDER_DRY_RUN=1 ./scripts/release.sh 1.0 42
```

Dry run validates the local configuration and prints the release plan. It does
not archive, sign, notarize, upload, or write git changes. It now runs the same
release preflight as the real release, because a dry run that skips the scary
checks is just theater with a timestamp. It also runs the remote Worker
preflight, so Wrangler must be authenticated even for release dry runs.

## Release Preflight

```bash
bash scripts/release_preflight.sh
```

Run this before every public build. It does not call `xcodebuild`. It checks the
release-facing configuration: shared Xcode scheme, bundle identifier, appcast
URL, Worker URL, D1 placeholder, Hardened Runtime, `spider://` magic link setup,
legacy provider references, obvious committed secrets, the Worker behavior smoke
test, and the grounding telemetry audit positive/negative self-test.

The Worker smoke test bundles the real Worker with Wrangler and exercises CORS,
auth-before-payload parsing, magic-link browser bridge safety, login email hash
hygiene, Stripe signature gating, and scheduled cleanup with local mocks only.
Use `SPIDER_SKIP_WORKER_SMOKE=1` only for a quick static config pass, not for
public beta release approval.

For Worker deploy readiness specifically, run:

```bash
bash scripts/worker_deploy_preflight.sh
```

That gate is intentionally local. It checks production-shaped Worker URLs, D1
database id shape, migration ordering, required secret documentation, and the
Worker package scripts before anyone runs a Cloudflare deploy. It does not prove
that the remote Cloudflare account has the secrets set; Wrangler auth still has
to be real before deployment.

Once Wrangler is authenticated, run the remote Worker gate:

```bash
bash scripts/worker_remote_preflight.sh
```

It checks `wrangler whoami`, remote secret names via `wrangler secret list
--format json`, remote D1 migration status via `wrangler d1 migrations list DB
--remote`, and `wrangler deploy --dry-run --strict`. It does not print secret
values, apply migrations, or deploy. If migrations are pending, stop and apply
them deliberately; do not hide that inside a release script.

The preflight is allowed to fail during development. For public beta it must
pass, with any warnings reviewed deliberately.

App Sandbox is currently a documented beta exception in
`SPIDER_SECURITY_RELEASE_DECISIONS.md`. Do not remove that file to quiet a gate.
Before stable release, the sandbox path must be retested in a branch or the
exception must be renewed with real evidence. Sexy? No. The alternative is
shipping a screen-reading app with an invisible security decision, which is
worse.

## Worktree Review Groups

```bash
node scripts/worktree_review_groups.mjs
node scripts/worktree_review_groups.mjs --summary
node scripts/worktree_review_groups.mjs --group telemetry-privacy
node scripts/worktree_review_groups.mjs --flag security-review
node scripts/worktree_review_groups.mjs --group worker-backend --flag security-review
node scripts/worktree_review_groups.mjs --paths --group telemetry-privacy
node scripts/worktree_review_groups.mjs --paths --null --group xcode-assets-deletions
node scripts/worktree_review_groups.mjs --json
node scripts/worktree_review_groups.mjs --self-test
```

Use this when the worktree is too large to review honestly. It reads
`git status --porcelain` and groups changed paths into the review domains Spider
uses for hygiene work: macOS core, guided setup/dot/sensor fusion,
telemetry/privacy, Worker backend, tests, docs/scripts/release, and
Xcode/assets/deletions.

The script does not write files, stage changes, run builds, or bless the diff.
It only makes the review order explicit and flags files that need manual review,
such as project metadata, lockfiles, release config, deletions, auth/session,
OpenAI, Stripe, billing, payload validation, telemetry, overlay, and dot logic.

Use `--paths` when you need the raw path list for a filtered group. Use
`--paths --null` for any command that consumes file paths, because this worktree
contains assets with spaces in their names. For example, after reviewing a group
and deciding it is safe to stage as a unit:

```bash
node scripts/worktree_review_groups.mjs --paths --null --group telemetry-privacy \
  | git add --pathspec-from-file=- --pathspec-file-nul
```

That command is intentionally not run by the review tool. A human still owns the
commit boundary.

Use the suggested commit groups as a starting point, not as an excuse to avoid
reading the diff. Xcode project changes, assets, lockfiles, `wrangler.toml`, and
`appcast.xml` stay manual-review items even when tests pass.

## Environment

- `SPIDER_RELEASE_REPO`: required GitHub release repo, for example `owner/spider-mac-app`.
- `SPIDER_NOTARY_PROFILE`: notarytool Keychain profile. Default: `AC_PASSWORD`.
- `SPIDER_DEVELOPMENT_TEAM`: Apple Developer Team ID passed to `xcodebuild`.
- `SPIDER_SPARKLE_BIN`: directory containing Sparkle `sign_update` and `generate_appcast`.
- `SPIDER_SKIP_CLEAN_CHECK=1`: bypasses the clean-worktree guard. Use only if you know exactly why.
- `SPIDER_SKIP_WORKER_SMOKE=1`: bypasses Worker smoke tests in preflight. Do not use for public beta release approval.
- `SPIDER_APPCAST_URL`: production HTTPS URL for the hosted Sparkle `appcast.xml`.
- `SPIDER_WORKER_BASE_URL`: production HTTPS origin for the Worker, no path/query/port.
- `SPIDER_LOGIN_CONFIRM_URL`: production HTTPS Worker `/auth/login/confirm` URL.
- `SPIDER_STRIPE_SUCCESS_URL`: production HTTPS page for successful checkout returns.
- `SPIDER_STRIPE_CANCEL_URL`: production HTTPS page for canceled checkout returns.
- `SPIDER_D1_DATABASE_ID`: Cloudflare D1 database UUID for the production database.
- `SPIDER_CONFIGURE_DRY_RUN=1`: validates release config inputs without writing `Info.plist` or `wrangler.toml`.

## One-Time Setup

1. Install Xcode and make sure the Developer ID Application certificate is in Keychain.
2. Install release tools:

   ```bash
   brew install create-dmg gh
   ```

3. Authenticate GitHub CLI:

   ```bash
   gh auth login
   ```

4. Store Apple notarization credentials:

   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID
   ```

5. Build the project in Xcode once so SwiftPM downloads Sparkle and the Sparkle
   CLI tools exist in DerivedData.

6. Configure production release settings:

   ```bash
   SPIDER_APPCAST_URL="https://<release-host>/spider/appcast.xml" \
   SPIDER_WORKER_BASE_URL="https://<api-host>" \
   SPIDER_LOGIN_CONFIRM_URL="https://<api-host>/auth/login/confirm" \
   SPIDER_STRIPE_SUCCESS_URL="https://<app-host>/account" \
   SPIDER_STRIPE_CANCEL_URL="https://<app-host>/account" \
   SPIDER_D1_DATABASE_ID="<cloudflare-d1-database-uuid>" \
   bash scripts/configure_release.sh
   ```

7. Confirm the app has production release settings:

   - Real bundle identifier, not `com.yourcompany.leanring-buddy`.
   - Developer Team configured.
   - Hardened Runtime enabled for Developer ID distribution.
   - App Sandbox exception reviewed in `SPIDER_SECURITY_RELEASE_DECISIONS.md`.
   - Sparkle appcast URL points to the real hosted `appcast.xml`.
   - Worker production URL configured in `Info.plist`.
   - Stripe, Resend, OpenAI, and `EMAIL_HASH_SECRET` set as Cloudflare secrets, never in the app.

## Release Flow

1. Verify the app from Xcode on a clean local account or machine.
2. Run `configure_release.sh` with the production values.
3. Run `bash scripts/worker_deploy_preflight.sh`.
4. Run `bash scripts/worker_remote_preflight.sh` with Cloudflare auth available.
5. Run `cd worker && npm run dry-run`.
6. Run a dry run with explicit version and build.
7. Run `bash scripts/release_preflight.sh` and fix every error.
8. Commit the exact source state you are releasing.
9. Run `release.sh` from that clean commit. It will run both local release preflight and remote Worker preflight again before archive/export.
10. Install the produced DMG on a clean Mac.
11. Confirm login, payment gating, screen permission, mic permission, GPT Vision guidance, and Realtime voice.
12. Keep Sparkle automatic updates disabled until the first beta has a validated appcast and rollback plan.
