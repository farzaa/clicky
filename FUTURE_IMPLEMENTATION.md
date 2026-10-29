# Future Implementation — Clicky Fork

Planned features captured from product brainstorming. Not implemented yet.

**Implementation order & E2E test plan:** see [`IMPLEMENTATION_AND_E2E_PLAN.md`](./IMPLEMENTATION_AND_E2E_PLAN.md) — implement Evolving Teaching Skills first, then run automated user-perspective E2E tests.

---

## 1. Evolving Teaching Skills (Auto-Learning)

**Problem:** Clicky starts from zero every session. It does not accumulate knowledge about how to teach specific apps or workflows.

**Concept:** After successful tutoring interactions, Clicky writes reusable teaching skills locally — inspired by Hermes Agent's learning loop, adapted for screen-native teaching (not CLI automation).

### What a teaching skill is

A folder under `~/.clicky/skills/<skill-name>/SKILL.md` using the [agentskills.io](https://agentskills.io) format:

- App or workflow name (e.g. `teach-final-cut-color`, `teach-xcode-source-control`)
- Step order and common user mistakes
- UI vocabulary (button labels, menu paths, shortcuts)
- Pointing heuristics (where to point first, what to avoid)
- Completion signals ("user said got it", step confirmed, correct UI state visible)

### Learning loop

1. User completes a tutoring session (push-to-talk + screen + pointing).
2. Clicky evaluates whether the session is worth persisting (multi-step help, user confirmed success, or repeated topic).
3. Clicky writes or updates a `SKILL.md` with what worked.
4. Next session: relevant skills are loaded into the system prompt when matching apps or topics appear on screen.

### Curator (maintenance)

Prevent skill bloat and stale UI knowledge:

- Track usage: viewed, used, patched
- Auto-transition: `active → stale → archived` after inactivity (e.g. 30 / 90 days)
- Optional LLM review pass to merge duplicates or patch drift when app UI changes
- User can pin important skills so they are never archived

### Triggers (when to create/update a skill)

- Multi-step guidance completed successfully
- User explicitly confirms ("got it", "thanks that worked")
- Same topic asked 2+ times in one week
- NOT: generic Q&A unrelated to screen UI

### Implementation notes

| Layer | Approach |
|-------|----------|
| Storage | `~/.clicky/skills/` (local only, privacy-first) |
| Format | `SKILL.md` with YAML frontmatter (`name`, `description`, optional `paths` for app bundles) |
| Injection | Extend `companionVoiceResponseSystemPrompt` with matched skills at request time |
| Worker | Optional `/skill-synthesize` route for post-session skill drafting (keeps API keys off-device) |
| Swift | New `TeachingSkillStore`, `SkillCurator`, hook in `CompanionManager` after successful responses |
| Phase 2 | GEPA-style optimization from traces (Hermes self-evolution pattern) — research/demo only |

### Success criteria

- Repeat questions on the same app get faster, more accurate pointing
- Skills stay small and relevant (Curator prevents catalog pollution)
- Demo: "Clicky remembered how to teach me Xcode commits from last week"

---

## 2. Niche Discovery (Onboarding + Suggestions)

**Problem:** Many users do not know what Clicky is for or what to ask. Blank-slate AI assistants fail the "first 60 seconds" test.

**Concept:** Help users discover Clicky through niche-specific, concrete examples — not generic "I'm an AI helper" messaging.

### Core UX

1. **Onboarding:** Ask what the user does (content creator, developer, student, designer, etc.) or infer from screen.
2. **Suggestion cards:** Show 3–5 actionable example prompts in the menu bar panel.
3. **Spoken intro (optional):** Clicky briefly explains what it can do *for their niche* via TTS.
4. **Live suggestions:** When screen context matches (e.g. Final Cut, OBS, Premiere), surface timely prompts.

### Example — Content creators

- "Show me where to add captions in this timeline"
- "Walk me through export settings for YouTube"
- "How do I color grade this clip?"
- "Where is the transition menu?"

Each suggestion should imply: **voice + screen + pointing**, not plain chat.

### Niche packs (optional, pairs with teaching skills)

```
~/.clicky/niches/
  content-creator/
    examples.json      # suggested prompts
    intro-script.txt     # optional spoken onboarding
  developer/
    examples.json
  student/
    examples.json
```

Niche selection can seed which teaching skills to prioritize and which apps to watch for.

### Detection strategies

| Method | Effort | Notes |
|--------|--------|-------|
| User picks niche in onboarding | Low | Store in UserDefaults (`selectedUserNiche`) |
| Frontmost app bundle ID | Medium | Map `com.apple.FinalCut` → content creator suggestions |
| Screenshot + Claude one-shot classify | Medium | Fallback when app mapping unknown |
| Proactive idle suggestions | Higher | Tutor mode synergy — suggest when user pauses in a known app |

### Implementation notes

| Layer | Approach |
|-------|----------|
| Swift | `NicheDiscoveryManager`, extend `CompanionPanelView` with suggestion UI |
| Persistence | `UserDefaults` for niche; optional `~/.clicky/profile.md` for richer profile |
| Prompts | Niche-specific example strings + optional niche clause in system prompt |
| Screen | Reuse `CompanionScreenCaptureUtility` + frontmost app from `NSWorkspace` |
| Analytics | Track which suggestions get tapped / spoken (PostHog via existing `ClickyAnalytics`) |

### Success criteria

- New users ask a useful question within first session (measurable via analytics)
- Reduced "what do I use this for?" support confusion
- Niche feels personal: content creators see creator examples, not developer ones

---

## Suggested build order

1. **Niche discovery (light)** — onboarding picker + static suggestion cards per niche
2. **App-aware suggestions** — detect frontmost app, swap examples dynamically
3. **Teaching skills (write)** — post-session skill creation for successful multi-step help
4. **Teaching skills (read + Curator)** — load skills into prompts, maintain library over time
5. **Combine** — niche picks starting suggestions; skills deepen tutoring in that niche over time

---

## Out of scope (for this fork)

- Full Hermes Agent port (Telegram, VPS, 20+ tools)
- Cloud skill sync / marketplace (local-first unless explicitly added later)
- Replacing push-to-talk with Realtime API (separate future idea)

---

## References

- Hermes Agent skills + Curator: https://github.com/NousResearch/hermes-agent
- Agent Skills standard: https://agentskills.io
- Related fork ideas: Skilly (teaching skills), moonmidas/clicky (Tutor mode)
