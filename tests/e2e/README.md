# Evolving Teaching Skills — E2E Automation

Clicky needs more than XCUITest because the real flow uses push-to-talk, microphone, screen capture, global shortcuts, and LLM responses.

## Stack

| Layer | Tool | Purpose |
|-------|------|---------|
| Permissions | `@guidepup/setup` or `tccutil` | Pre-grant Screen Recording, Mic, Accessibility |
| Push-to-talk | `NaryaAI/voice-testing-tools` | Simulate `ctrl+option` via HID events |
| Voice input | `tts.mjs` + BlackHole 2ch | Deterministic TTS into virtual mic |
| Screen/UI | Peekaboo or `axcli` | Launch apps, verify overlay/cursor |
| AI | Mock worker fixtures | Repeatable pass/fail without live Claude |

## One-time setup

```bash
npx @guidepup/setup --ci
brew install blackhole-2ch sox switchaudio-osx
```

Use stable code signing so TCC permissions survive rebuilds.

## Fast path (inject transcript)

For skill-loop testing without mic/STT:

```bash
open /path/to/Clicky.app --args \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL=http://127.0.0.1:8787 \
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document?"
```

Then confirm success:

```bash
open -a Clicky --args \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL=http://127.0.0.1:8787 \
  -CLICKY_INJECT_TRANSCRIPT="got it thanks that worked"
```

Assert:

```bash
test -f ~/.clicky/skills/teach-textedit-save/SKILL.md
```

Or run the bundled script:

```bash
chmod +x tests/e2e/teaching-skills.sh
CLICKY_APP=/path/to/Clicky.app CLICKY_WORKER_URL=http://127.0.0.1:8787 ./tests/e2e/teaching-skills.sh
```

## Full user-perspective path

1. Launch Clicky + fixture app (`TextEdit`, `Xcode`, etc.)
2. Play TTS into BlackHole while holding push-to-talk with `simulate-keypress.swift`
3. Confirm with a second spoken phrase
4. Use Peekaboo to verify overlay/pointing and read `lastMatchedSkillNames` if exposed via debug hooks
5. Assert skill file exists and a repeat question loads the skill into `lastSystemPrompt`

## E2E launch flags

- `-CLICKY_E2E=1` — skip onboarding defaults, faster test startup
- `-CLICKY_WORKER_URL=<url>` — point API calls at mock worker
- `-CLICKY_INJECT_TRANSCRIPT=<text>` — bypass mic/STT and run response + skill loop directly

## Mock worker

Record Claude `/chat` fixtures once, then replay them in CI. Keep vision and synthesis responses separate so skill writes stay deterministic.

## What to assert

1. Skill file created under `~/.clicky/skills/`
2. Second session includes skill content in composed system prompt
3. Pointing tag present when skill includes UI guidance
4. Curator archives stale skills after inactivity (unit-tested separately)
