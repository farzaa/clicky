# Full-Stack User-Perspective E2E

Automated and manual end-to-end tests for the **real** Clicky path: microphone, push-to-talk, screen capture, overlay, and mock AI responses.

Headless CI regression remains [`../run-all.sh`](../run-all.sh) (no mic/TCC required).

## One-command automated run

```bash
chmod +x tests/e2e/full-stack/*.sh tests/e2e/full-stack/clicky-overlay.axcli.sh
./tests/e2e/full-stack/setup.sh          # one-time
./tests/e2e/full-stack/run-automated.sh  # automated PTT journey
```

Or via run-all:

```bash
./tests/e2e/run-all.sh --full-stack
```

If BlackHole, voice-testing-tools, or SwitchAudioSource are missing, the script exits **0** with:

```
SKIPPED: full-stack prerequisites not met
```

This ensures CI never fails when `--full-stack` is not used or prerequisites are absent.

## Prerequisites

| Tool | Install |
|------|---------|
| BlackHole 2ch | `brew install blackhole-2ch` |
| SwitchAudioSource | `brew install switchaudio-osx` |
| sox (optional) | `brew install sox` |
| voice-testing-tools | `./setup.sh` clones to `vendor/voice-testing-tools` |
| axcli (optional) | `brew install axcli` — overlay assertions |
| TCC pre-seed | `npx @guidepup/setup --ci` (one-time on test Mac) |
| Stable signing | Dev/Developer ID cert — ad-hoc resets TCC each rebuild |

## What `run-automated.sh` does

1. Checks prerequisites (skip gracefully if missing)
2. Builds Clicky (or reuses `build/E2E/Clicky.app`)
3. Starts mock worker
4. Opens TextEdit
5. Launches Clicky **without** transcript inject
6. Routes audio to BlackHole (best-effort)
7. Simulates PTT twice (question + confirmation) via voice-testing-tools
8. Asserts skill file exists
9. Optionally asserts overlay via `clicky-overlay.axcli.sh`
10. Relaunches, PTT same question, asserts `e2e-last-matched-skill-id.txt`

## Overlay assertions (axcli)

```bash
./tests/e2e/full-stack/clicky-overlay.axcli.sh clicky.overlay.waveform
./tests/e2e/full-stack/clicky-overlay.axcli.sh clicky.overlay.cursor
```

If axcli is not installed, overlay checks print WARNING and rely on file artifacts.

## Manual scaffold (exploratory)

```bash
./tests/e2e/full-stack/run-full-stack.sh
```

Prints step-by-step manual instructions and verifies headless E2E still passes.

## Self-hosted GitHub Actions (optional)

If you have a self-hosted macOS runner with TCC pre-seeded and BlackHole installed:

```yaml
# .github/workflows/e2e-full-stack.yml (example — not enabled by default)
name: E2E Full Stack
on:
  workflow_dispatch:

jobs:
  full-stack:
    runs-on: [self-hosted, macOS]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - run: |
          chmod +x tests/e2e/run-all.sh tests/e2e/full-stack/*.sh
          ./tests/e2e/full-stack/setup.sh
          ./tests/e2e/run-all.sh --full-stack
```

## E2E artifacts

Same as headless — see [`../README.md`](../README.md).

## Related

- Manual checklist: [`../USER_JOURNEY.md`](../USER_JOURNEY.md)
- Headless CI: [`../README.md`](../README.md)
