# Niche Discovery — Manual Validation

Worktree: `feature/niche-discovery`

## Quick manual test (Cmd+R from Xcode)

1. Open **`/Users/cristeaoctavian/projects/clicky-worktrees/niche-discovery/leanring-buddy.xcodeproj`**
2. Run Clicky (Cmd+R) — do not use terminal `xcodebuild` (preserves TCC permissions)
3. Complete onboarding if needed, then open the menu bar panel

### Suggestion cards

- [ ] Panel shows **3 suggestion chips** under the Control+Option instructions
- [ ] In **Ghostty**: context says *"While you're in Ghostty…"* with terminal prompts
- [ ] Switch to **TextEdit** and reopen panel — cards change
- [ ] Tap a chip → panel closes, cursor appears, Clicky answers with screenshot + voice

### Implicit profile (optional, over time)

- [ ] `~/.clicky/app-usage.json` grows as you switch apps
- [ ] After heavy dev usage, neutral apps (Safari) bias toward developer prompts when profile is stable

### Override

- [ ] **Suggestions feel wrong?** reveals niche picker
- [ ] Pick **Developer** → cards update; **Use automatic suggestions again** clears override

## Unit tests

In Xcode: **Product → Test** (scheme `leanring-buddy`, `NicheDiscoveryTests`).

## Headless E2E (optional, uses xcodebuild)

```bash
cd /Users/cristeaoctavian/projects/clicky-worktrees/niche-discovery
./tests/e2e/niche-discovery.sh
```

## Simulation script (profile research)

```bash
python3 /Users/cristeaoctavian/Projects/clicky/scripts/niche-discovery/simulate-niche-discovery.py
```
