# Evolving Teaching Skills — Implementation & E2E Plan

Captured from product/eng discussion. **Order of work: implement the feature first, then run full automated E2E tests.**

Related: [`FUTURE_IMPLEMENTATION.md`](./FUTURE_IMPLEMENTATION.md) (feature spec)

---

## Goal

Clicky learns from successful tutoring sessions and reuses that knowledge in future sessions via local `SKILL.md` files under `~/.clicky/skills/`.

**Demo success:** *"I taught Clicky how to walk me through Xcode commits yesterday — today it remembers and points better on the first try."*

---

## Phase 1 — Foundation (implement first)

1. **`TeachingSkillStore.swift`**
   - Create/read/update skills at `~/.clicky/skills/<name>/SKILL.md`
   - Parse YAML frontmatter: `name`, `description`, `bundleIds`, `status`, `lastUsed`, `usageCount`
   - Index skills on app launch

2. **Session trace capture**
   - Extend `CompanionManager` beyond in-RAM `conversationHistory` (~10 turns)
   - Persist lightweight session log: transcript, response, frontmost app bundle ID, pointing used or not
   - Hook after each successful exchange in `sendTranscriptToClaudeWithScreenshot`

3. **Skill matching at request time**
   - Frontmost app via `NSWorkspace.shared.frontmostApplication`
   - Match by bundle ID + keyword overlap with user transcript
   - Load top 1–3 skills into system prompt (small token budget)

4. **Prompt injection**
   - Replace static `companionVoiceResponseSystemPrompt` with a builder:
     - base Clicky prompt
     - + matched teaching skills
   - Pass composed prompt to `claudeAPI.analyzeImageStreaming`

---

## Phase 2 — Write loop (evolving)

5. **Trigger evaluator**
   - After session / N exchanges, decide create-or-update:
     - multi-step help (2+ exchanges with pointing)
     - user confirms ("got it", "thanks", "that worked")
     - same topic repeated within 7 days
   - Skip generic off-screen Q&A

6. **Skill synthesizer**
   - Option A: local Claude call via existing `/chat` worker with synthesis prompt
   - Option B: new worker route `POST /skill-synthesize`
   - Input: session trace → Output: `SKILL.md` (steps, UI labels, pointing tips, mistakes)

7. **Create vs update**
   - Merge into existing similar skill instead of duplicating
   - Bump `lastUsed`, increment `usageCount`

---

## Phase 3 — Curator

8. **`SkillCurator.swift`**
   - Track: viewed, used, patched, archived
   - Auto-archive: 30d inactive → stale, 90d → archived
   - User pin (never archive)
   - Optional LLM pass to merge duplicates / patch stale UI labels

---

## Phase 4 — UX (recommended)

9. **Minimal UI in `CompanionPanelView`**
   - List skills, pin/delete, toggle "learn from sessions"

10. **Analytics**
    - Track: skill matched, created, used (via `ClickyAnalytics` / PostHog)

---

## Files to touch

| File | Role |
|------|------|
| `CompanionManager.swift` | trace capture, triggers, prompt builder, post-session hook |
| **New** `TeachingSkillStore.swift` | filesystem + parsing |
| **New** `SkillCurator.swift` | lifecycle + dedup |
| **New** `SkillMatcher.swift` | app/topic matching |
| `CompanionPanelView.swift` | skills UI |
| `worker/src/index.ts` | optional `/skill-synthesize` |

---

## E2E automation — full user-perspective stack

Pure XCUITest alone is not enough for Clicky (mic, screen capture, global shortcuts, pointing overlay, LLM). Use this macOS automation stack instead.

| Layer | Tool | Purpose |
|-------|------|---------|
| Permissions | [`@guidepup/setup`](https://github.com/guidepup/setup) or [`jacobsalmela/tccutil`](https://github.com/jacobsalmela/tccutil) | Pre-grant Screen Recording, Mic, Accessibility in TCC.db |
| Push-to-talk | [`NaryaAI/voice-testing-tools`](https://github.com/NaryaAI/voice-testing-tools) `simulate-keypress.swift` | Hold/release `ctrl+option` (Clicky's shortcut) via HID events |
| Voice input | Same repo `tts.mjs` + **BlackHole 2ch** | Deterministic TTS → virtual mic → real STT path |
| Screen + UI | [**Peekaboo**](https://github.com/steipete/Peekaboo) `.peekaboo.json` or [**axcli**](https://github.com/andelf/axcli) | Launch app, screenshots, verify overlay/cursor, AX tree |
| Deterministic AI | Mock worker with recorded Claude fixtures | Repeatable pass/fail (real API is flaky) |

### Prerequisites

1. **Stable code signing** — ad-hoc builds reset TCC on every rebuild; use dev/Developer ID cert so permissions persist.
2. **Self-hosted Mac test machine** — one-time TCC pre-seed via `@guidepup/setup`; fully unattended cloud CI without setup is unreliable.
3. **BlackHole as mic input** during tests to exercise real transcription.
4. **Mock worker** for E2E assertions (record/replay fixtures).

### Example E2E flow

```bash
# One-time setup
npx @guidepup/setup --ci
brew install blackhole-2ch sox switchaudio-osx

# Launch Clicky + fixture app
open /path/to/Clicky.app
open -a TextEdit

# Session 1: ask for help
node tools/tts.mjs "how do I save this document?" &
swift tools/simulate-keypress.swift down:ctrl down:option wait:3000 up:option up:ctrl

# Confirm success (triggers skill write)
node tools/tts.mjs "got it thanks that worked" &
swift tools/simulate-keypress.swift down:ctrl down:option wait:2000 up:option up:ctrl

# Assert skill file exists
test -f ~/.clicky/skills/teach-textedit-save/SKILL.md

# Session 2: repeat question, verify skill loaded + pointing
peekaboo run tests/e2e/teaching-skills.peekaboo.json --json
```

### Clicky test hooks to add (small, E2E-friendly)

- Launch flag `-CLICKY_E2E=1`: skip onboarding, point at test worker URL, faster timeouts
- Optional `--inject-transcript` fallback if STT flakes (still runs response + skill loop)
- Expose for assertions: `lastSystemPrompt`, `lastSkillMatched`, overlay accessibility identifiers

---

## Execution order

1. Implement Phases 1–2 (read + write loop) — minimum viable evolving skills
2. Add test hooks + mock worker fixtures
3. Scaffold `tests/e2e/` (voice-testing-tools + Peekaboo scripts)
4. One-time Mac test machine setup (TCC, BlackHole, signing)
5. Run full E2E regression
6. Phase 3–4 (Curator + UI) as follow-up

---

## References

- Hermes Agent skills + Curator: https://github.com/NousResearch/hermes-agent
- Agent Skills standard: https://agentskills.io
- Voice E2E tools: https://github.com/NaryaAI/voice-testing-tools
- macOS GUI automation: https://github.com/steipete/Peekaboo
- TCC automation: https://github.com/guidepup/setup
