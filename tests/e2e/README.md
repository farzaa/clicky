# Evolving Teaching Skills — E2E Automation

Headless E2E for the teaching-skills write path (Phase A) and read path (Phase B). Uses a mock Cloudflare Worker — no live Claude or ElevenLabs keys required.

## One-command run

From the repo root:

```bash
chmod +x tests/e2e/run-all.sh tests/e2e/teaching-skills.sh
./tests/e2e/run-all.sh
echo exit:$?
```

Or invoke the test script directly:

```bash
./tests/e2e/teaching-skills.sh
```

Optional environment overrides:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLICKY_APP` | `build/E2E/Clicky.app` | Built app bundle path |
| `CLICKY_WORKER_URL` | `http://127.0.0.1:8787` | Mock worker base URL |

### Expected PASS output

```
Building Clicky for E2E...
Starting mock worker on http://127.0.0.1:8787...
Resetting prior teaching skills...
Phase A: launch Clicky and teach a save workflow...
PASS: teaching skill written to ~/.clicky/skills/teach-<app>-save/SKILL.md
--- skill preview ---
...
PASS: skill slug is clean (teach-<app>-save)
Phase B: relaunch Clicky and verify saved skill is injected into prompt...
PASS: saved skill content found in composed system prompt
--- prompt preview ---
teaching skills:
...

E2E PASS: Phase A (write) + Phase B (read-path) succeeded
```

Exit code `0` on success, non-zero on any failure.

## What the test verifies

### Phase A — Write path

1. Builds Clicky unsigned (`CODE_SIGN_IDENTITY="-"`, `CODE_SIGNING_ALLOWED=NO`)
2. Starts `tests/e2e/mock-worker.mjs` on port 8787
3. Clears `~/.clicky/skills/` and `~/.clicky/e2e-last-system-prompt.txt`
4. Launches Clicky with injected transcripts (question + confirmation)
5. Asserts within 30s:
   - `~/.clicky/skills/*/SKILL.md` exists
   - Skill slug contains `save`
   - Slug does **not** contain `got`, `thanks`, or `worked`

### Phase B — Read path

1. Kills Clicky from Phase A (skills remain on disk)
2. Relaunches with `-CLICKY_INJECT_TRANSCRIPT_3="how do I save this document?"`
3. Asserts within 30s:
   - `~/.clicky/e2e-last-system-prompt.txt` exists
   - File contains `teaching skills:`
   - File contains `save` (saved skill injected into system prompt)

## CI

GitHub Actions workflow: [`.github/workflows/e2e-teaching-skills.yml`](../../.github/workflows/e2e-teaching-skills.yml)

- Triggers on `push` and `pull_request` to `main`
- Runner: `macos-14`
- Runs `./tests/e2e/run-all.sh`
- Uploads `/tmp/clicky-e2e-*.log` and `~/.clicky/e2e-last-system-prompt.txt` as artifacts on failure

Optional CI badge (after the workflow has run on GitHub):

```markdown
![E2E Teaching Skills](https://github.com/<owner>/<repo>/actions/workflows/e2e-teaching-skills.yml/badge.svg)
```

### Unit tests in CI

The workflow attempts `xcodebuild build-for-testing` before E2E. The shared Xcode scheme currently does not include `leanring-buddyTests`, so this step is best-effort (`continue-on-error: true`) and does not block E2E. Unit tests live in `leanring-buddyTests/TeachingSkillTests.swift` and can be run from Xcode until the scheme is wired.

## Troubleshooting

Log files (overwritten each run):

| Log | Contents |
|-----|----------|
| `/tmp/clicky-e2e-build.log` | Xcode build output |
| `/tmp/clicky-e2e-worker.log` | Mock worker stdout |
| `/tmp/clicky-e2e-app.log` | Clicky stdout during Phase A |
| `/tmp/clicky-e2e-app-read.log` | Clicky stdout during Phase B |

Debug artifacts under `~/.clicky/`:

| Path | Purpose |
|------|---------|
| `~/.clicky/skills/<id>/SKILL.md` | Saved teaching skill |
| `~/.clicky/e2e-last-system-prompt.txt` | Last composed system prompt (E2E mode) |

Common failures:

- **Build fails** — check `/tmp/clicky-e2e-build.log`; requires Xcode and macOS 14.2+ SDK
- **No skill written in 30s** — check `/tmp/clicky-e2e-app.log` and worker log; mock worker must be reachable at `127.0.0.1:8787`
- **Read path fails** — skill from Phase A must still exist under `~/.clicky/skills/`; check `/tmp/clicky-e2e-app-read.log`

## E2E launch flags

Defined in `leanring-buddy/ClickyE2EConfiguration.swift`:

- `-CLICKY_E2E=1` — skip onboarding defaults, faster test startup
- `-CLICKY_WORKER_URL=<url>` — point API calls at mock worker
- `-CLICKY_INJECT_TRANSCRIPT=<text>` — first injected transcript (write path)
- `-CLICKY_INJECT_TRANSCRIPT_2=<text>` — second injected transcript (confirmation)
- `-CLICKY_INJECT_TRANSCRIPT_3=<text>` — read-path-only launch (skills already on disk)

Writes `~/.clicky/e2e-last-system-prompt.txt` on each injected response for headless assertions.

## Mock worker

`tests/e2e/mock-worker.mjs` serves deterministic `/chat` and `/tts` responses on `http://127.0.0.1:8787`. Streaming responses include a `[POINT:...]` tag; non-streaming synthesis responses produce skill body content.

```bash
node tests/e2e/mock-worker.mjs
```

## Manual inject (without full E2E script)

Write path only:

```bash
open build/E2E/Clicky.app --args \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL=http://127.0.0.1:8787 \
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document?" \
  -CLICKY_INJECT_TRANSCRIPT_2="got it thanks that worked"
```

Read path only (after a skill exists):

```bash
open build/E2E/Clicky.app --args \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL=http://127.0.0.1:8787 \
  -CLICKY_INJECT_TRANSCRIPT_3="how do I save this document?"

grep "teaching skills:" ~/.clicky/e2e-last-system-prompt.txt
```

## Full user-perspective path (future)

Not covered by the current headless E2E script:

| Layer | Tool | Purpose |
|-------|------|---------|
| Permissions | `@guidepup/setup` or `tccutil` | Pre-grant Screen Recording, Mic, Accessibility |
| Push-to-talk | `NaryaAI/voice-testing-tools` | Simulate `ctrl+option` via HID events |
| Voice input | `tts.mjs` + BlackHole 2ch | Deterministic TTS into virtual mic |
| Screen/UI | Peekaboo or `axcli` | Launch apps, verify overlay/cursor |

TCC permission seeding in CI is documented as a follow-up — it can be flaky on ephemeral runners.

## Related unit tests

`leanring-buddyTests/TeachingSkillTests.swift` covers topic extraction, slug generation, cross-session repeat detection, and prompt injection logic without launching the app.
