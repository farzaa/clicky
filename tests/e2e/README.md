# Evolving Teaching Skills — E2E Automation

Headless E2E for teaching skills, niche discovery, skills library, and the full demo user journey. Uses a mock Cloudflare Worker — no live Claude or ElevenLabs keys required.

## One-command run

From the repo root:

```bash
chmod +x tests/e2e/run-all.sh tests/e2e/*.sh tests/e2e/lib/common.sh
./tests/e2e/run-all.sh
echo exit:$?
```

Optional full-stack (real PTT/mic — self-hosted Mac only):

```bash
./tests/e2e/run-all.sh --full-stack
```

### Scripts run by `run-all.sh`

| Script | Coverage |
|--------|----------|
| `teaching-skills.sh` | Skill write + read path |
| `niche-discovery.sh` | Niche select, app-aware swap, local override |
| `skills-library.sh` | Library snapshot + restore hook |
| `full-user-journey.sh` | End-to-end demo success story (write → recall → niche) |
| `full-stack/run-automated.sh` | Only with `--full-stack`; skips if prerequisites missing |

Optional environment overrides:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLICKY_APP` | `build/E2E/Clicky.app` | Built app bundle path |
| `CLICKY_WORKER_URL` | `http://127.0.0.1:8787` | Mock worker base URL |
| `SKIP_E2E_BUILD` | unset | Set to `1` to reuse existing `CLICKY_APP` (set by `run-all.sh` after first build) |

## E2E launch flags

Defined in `leanring-buddy/ClickyE2EConfiguration.swift`:

| Flag | Purpose |
|------|---------|
| `-CLICKY_E2E=1` | Enable E2E mode; skip onboarding defaults (unless niche flags below) |
| `-CLICKY_WORKER_URL=<url>` | Point API calls at mock worker |
| `-CLICKY_INJECT_TRANSCRIPT=<text>` | First injected transcript (write path) |
| `-CLICKY_INJECT_TRANSCRIPT_2=<text>` | Second injected transcript (confirmation) |
| `-CLICKY_INJECT_TRANSCRIPT_3=<text>` | Read-path-only launch (skills already on disk) |
| `-CLICKY_E2E_INCLUDE_NICHE=1` | Do **not** auto-skip niche in launch overrides |
| `-CLICKY_E2E_SELECT_NICHE=<rawValue>` | Programmatically select niche (e.g. `developer`) |
| `-CLICKY_E2E_SIMULATE_FRONTMOST_BUNDLE=<bundleId>` | Force app-aware suggestions (e.g. `com.apple.dt.Xcode`) |
| `-CLICKY_E2E_INJECT_SUGGESTION_TAP=<text>` | Simulate tapping a suggestion card |
| `-CLICKY_E2E_RESTORE_SKILL=<skillId>` | Restore archived/stale skill on launch |

## E2E file artifacts

Written under `~/.clicky/` when `-CLICKY_E2E=1`:

| File | Content |
|------|---------|
| `e2e-last-system-prompt.txt` | Last composed system prompt |
| `e2e-last-matched-skill-id.txt` | First matched teaching skill ID |
| `e2e-last-suggestions.txt` | JSON array of current suggestion strings |
| `e2e-selected-niche.txt` | Selected niche rawValue |
| `e2e-skills-count.txt` | Count of skills in store |
| `e2e-skill-library-state.txt` | JSON snapshot: `[{id, status, pinned}]` |

## Accessibility identifiers

### Panel (`CompanionPanelView`, `TeachingSkillsLibraryView`)

| Identifier | Element |
|------------|---------|
| `clicky.panel.niche.section` | Niche onboarding section |
| `clicky.panel.niche.<rawValue>` | Niche picker button (e.g. `developer`) |
| `clicky.panel.niche.skip` | Skip niche button |
| `clicky.panel.suggestions.section` | Suggestion cards section |
| `clicky.panel.suggestion.<index>` | Suggestion card (0-based) |
| `clicky.panel.teaching-skills.view-all` | View all skills link |
| `clicky.panel.teaching-skills.learn-toggle` | Learn-from-sessions toggle |
| `clicky.panel.skills-library.filter.<status>` | Library filter (all/active/stale/archived) |
| `clicky.panel.skills-library.row.<skillId>` | Library skill row |

### Overlay (`OverlayWindow.swift`)

| Identifier | Element |
|------------|---------|
| `clicky.overlay.cursor` | Blue triangle cursor |
| `clicky.overlay.waveform` | Listening waveform |
| `clicky.overlay.spinner` | Processing spinner |
| `clicky.overlay.pointing-bubble` | Pointing label bubble |
| `clicky.overlay.onboarding-prompt` | Onboarding prompt bubble |

## CI

GitHub Actions: [`.github/workflows/e2e-teaching-skills.yml`](../../.github/workflows/e2e-teaching-skills.yml)

1. `xcodebuild test` — `TeachingSkillTests` (required)
2. `./tests/e2e/run-all.sh` — all headless scripts

GitHub-hosted runners: headless only. Full-stack PTT requires a self-hosted Mac.

### Unit tests

```bash
xcodebuild test \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  -only-testing:leanring-buddyTests/TeachingSkillTests \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO
```

## Troubleshooting

| Log | Contents |
|-----|----------|
| `/tmp/clicky-e2e-build.log` | Xcode build |
| `/tmp/clicky-e2e-worker.log` | Mock worker |
| `/tmp/clicky-e2e-app*.log` | Clicky stdout per script phase |

Common failures:

- **Build fails** — check build log; requires Xcode macOS 14.2+ SDK
- **No skill in 30s** — check app + worker logs; worker must be at `127.0.0.1:8787`
- **Niche assertions fail** — verify `Resources/niche-examples.json` in app bundle

## Related docs

- Manual checklist: [`USER_JOURNEY.md`](USER_JOURNEY.md)
- Full-stack PTT: [`full-stack/README.md`](full-stack/README.md)
- Mock worker: `mock-worker.mjs`

## Mock worker

```bash
node tests/e2e/mock-worker.mjs
```

Serves deterministic `/chat` and `/tts` on `http://127.0.0.1:8787`.
