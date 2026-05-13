# Dot Safety Runbook

Use this when a production change risks breaking users, privacy, or spend.

## 1. Disable risky client features

Feature flags live in the `vibe-id` production D1 database and are returned from `/auth/me`.

```bash
cd ~/Desktop/projects/vibe-id/worker

# List current Dot flags.
./scripts/set-project-feature-flag.sh dot list

# Emergency examples.
./scripts/set-project-feature-flag.sh dot agent_tools_enabled 0
./scripts/set-project-feature-flag.sh dot background_agents_enabled 0
./scripts/set-project-feature-flag.sh dot memory_enabled 0
./scripts/set-project-feature-flag.sh dot tts_enabled 0
./scripts/set-project-feature-flag.sh dot remote_control_enabled 0
```

Effects:
- `agent_tools_enabled=0`: Dot still answers, but Anthropic receives no computer-control tools.
- `background_agents_enabled=0`: `dot agent ...` requests are rejected in the app.
- `memory_enabled=0`: the Anthropic memory tool is not exposed.
- `tts_enabled=0`: ElevenLabs requests stop; Dot falls back to macOS system speech.
- `remote_control_enabled=0`: phone/browser-issued commands cannot reach the Mac.

Re-enable with the same command and `1`.

## 2. Verify the core endpoints

```bash
cd ~/Desktop/projects/vibe-id
./worker/scripts/smoke-prod.sh
```

For authenticated coverage, use a dedicated smoke install token:

```bash
VIBE_ID_SMOKE_INSTALL_TOKEN="$TOKEN" ./worker/scripts/smoke-prod.sh
```

Only run billable checks deliberately:

```bash
VIBE_ID_SMOKE_INSTALL_TOKEN="$TOKEN" VIBE_ID_SMOKE_RUN_BILLABLE=1 ./worker/scripts/smoke-prod.sh
```

## 3. Roll back vibe-id

Fastest rollback is redeploying the prior known-good commit:

```bash
cd ~/Desktop/projects/vibe-id
git log --oneline --decorate --max-count=10
git checkout <known-good-sha>
cd worker
npm exec tsc -- --noEmit
npm exec wrangler -- deploy --dry-run
npm exec wrangler -- deploy
./scripts/smoke-prod.sh
```

After the incident, return to `main`:

```bash
git checkout main
git pull --ff-only
```

## 4. Roll back Dot app updates

If a released app build is bad, do not edit appcast by hand.

```bash
cd ~/Desktop/projects/dot
git revert <appcast-release-commit>
git push origin main
./scripts/smoke-release.sh <prior-version>
```

If the revert is only for the appcast during an emergency, run the boundary check intentionally:

```bash
DOT_RELEASE=1 ./scripts/check-release-boundaries.sh
```

## 5. Privacy boundary

Dot does not continuously record the screen. A turn sends the transcript and a fresh screenshot through Vibe Research to Claude. Keep these invariant:
- no raw transcripts in analytics
- no screenshots in analytics or server logs
- no model responses in analytics
- only usage counts, durations, status codes, and credit ledger records server-side
