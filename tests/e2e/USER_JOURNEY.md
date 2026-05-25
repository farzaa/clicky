# Clicky — Manual User Journey Checklist

Step-by-step smoke test for the full end-user experience. Each step maps to an automated script where possible.

## Quick reference

| Step | What you verify | Automated coverage |
|------|-----------------|-------------------|
| 1. Permissions | Mic, screen, accessibility granted | — (manual / `@guidepup/setup`) |
| 2. Niche onboarding | Pick niche or skip → general | `niche-discovery.sh`, `full-user-journey.sh` |
| 3. Suggestions | Cards match niche + frontmost app | `niche-discovery.sh` |
| 4. Teach Clicky | PTT → answer → confirm → skill saved | `teaching-skills.sh`, `full-user-journey.sh` |
| 5. Recall skill | Same question loads skill into prompt | `teaching-skills.sh`, `full-user-journey.sh` |
| 6. Skills library | View all, filter, restore archived | `skills-library.sh` |
| 7. Real voice path | BlackHole + PTT + overlay | `full-stack/run-automated.sh` (self-hosted Mac) |

---

## 1. Permissions

1. Fresh install or reset TCC (dev cert recommended — ad-hoc resets permissions each rebuild).
2. Open Clicky from menu bar.
3. Grant **Accessibility**, **Screen Recording**, **Microphone**, and **Screen Content**.

**Expected:** Panel shows “Hold Control+Option to talk.”

**Artifacts:** none

**Automated:** Not in CI. Pre-seed with `npx @guidepup/setup --ci` on a test Mac.

---

## 2. Niche onboarding

1. Before first onboarding, panel shows “What do you mostly use Clicky for?”
2. Pick **Developer** (or skip → general).
3. Complete email + Start if first run.

**Expected artifacts (E2E mode):**

| File | Expected |
|------|----------|
| `~/.clicky/e2e-selected-niche.txt` | `developer` (or `general` if skipped) |

**Automated:** `tests/e2e/niche-discovery.sh` Phase A

**Accessibility IDs:** `clicky.panel.niche.section`, `clicky.panel.niche.developer`, `clicky.panel.niche.skip`

---

## 3. Suggestion cards

1. After onboarding, panel shows “Try asking” with 3–5 cards.
2. Switch to **Xcode** — suggestions should change to Xcode-specific prompts.
3. Tap a card — text copies to clipboard (does **not** auto-record).

**Expected artifacts (E2E mode):**

| File | Expected |
|------|----------|
| `~/.clicky/e2e-last-suggestions.txt` | JSON array; includes niche/app-specific strings |

**Automated:** `niche-discovery.sh` Phases B + C; `full-user-journey.sh` Steps 4–5

**Accessibility IDs:** `clicky.panel.suggestions.section`, `clicky.panel.suggestion.0` …

**Local override (optional):**

```bash
mkdir -p ~/.clicky/niches/developer
echo '{"suggestions":["my custom prompt"]}' > ~/.clicky/niches/developer/examples.json
```

---

## 4. Teach Clicky (write path)

1. Open **TextEdit** (or any app).
2. Hold **Control+Option**, ask: “how do I save this document?”
3. Release, wait for response + pointing.
4. Hold **Control+Option** again: “got it thanks that worked”

**Expected:**

- Skill file: `~/.clicky/skills/teach-<app>-save/SKILL.md`
- Slug contains `save`, not confirmation words

**Expected artifacts (E2E inject mode):**

| File | Expected |
|------|----------|
| `~/.clicky/e2e-skills-count.txt` | `>= 1` |

**Automated:** `teaching-skills.sh` Phase A; `full-user-journey.sh` Step 2

---

## 5. Recall skill (read path)

1. Quit and relaunch Clicky (skill remains on disk).
2. Ask the same save question via PTT (or E2E inject).

**Expected artifacts:**

| File | Expected |
|------|----------|
| `~/.clicky/e2e-last-matched-skill-id.txt` | Matches saved skill ID |
| `~/.clicky/e2e-last-system-prompt.txt` | Contains `teaching skills:` and skill body |

**Automated:** `teaching-skills.sh` Phase B; `full-user-journey.sh` Step 3

---

## 6. Skills library

1. Menu bar panel → **Teaching Skills** → **View all**
2. Filter Active / Stale / Archived
3. Restore an archived skill (↩ button)

**Expected artifacts (E2E mode):**

| File | Expected |
|------|----------|
| `~/.clicky/e2e-skill-library-state.txt` | JSON: `[{id, status, pinned}, …]` |

**Automated:** `skills-library.sh`

**Accessibility IDs:** `clicky.panel.teaching-skills.view-all`, `clicky.panel.skills-library.filter.archived`, `clicky.panel.skills-library.row.<skillId>`

---

## 7. Curator (manual only)

1. Create duplicate skills with overlapping content (same app).
2. Relaunch Clicky — curator may merge one pair (requires live/mock Claude).
3. Set a skill to `stale` in frontmatter; relaunch — curator may patch it.

**Automated:** Unit tests cover duplicate **detection** only (`TeachingSkillTests`); LLM merge/patch not headless-E2E’d.

---

## 8. Full-stack real voice (self-hosted Mac)

**Prerequisites:** BlackHole 2ch, voice-testing-tools, SwitchAudioSource, TCC pre-seeded, stable signing.

```bash
./tests/e2e/full-stack/setup.sh
./tests/e2e/full-stack/run-automated.sh
# or via run-all:
./tests/e2e/run-all.sh --full-stack
```

**Expected:** Skill written via real PTT; overlay visible (axcli if installed); read path matches skill ID.

**If prerequisites missing:** Script exits 0 with `SKIPPED: full-stack prerequisites not met`.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Permissions re-requested every build | Use dev/Developer ID cert, not ad-hoc `CODE_SIGN_IDENTITY=-` |
| No skill written | Check mock worker at `127.0.0.1:8787`; logs in `/tmp/clicky-e2e-*.log` |
| Niche suggestions empty | Ensure `Resources/niche-examples.json` is in app bundle |
| Full-stack STT silent | Route output to BlackHole; set Clicky mic input to BlackHole 2ch |
| TCC blocks automation | Run `npx @guidepup/setup --ci` once on dedicated test Mac |

---

## One-command automation

```bash
# CI + local headless (unit tests separate in workflow)
./tests/e2e/run-all.sh

# Optional real PTT on self-hosted Mac
./tests/e2e/run-all.sh --full-stack
```

See also: [`README.md`](README.md), [`full-stack/README.md`](full-stack/README.md)
