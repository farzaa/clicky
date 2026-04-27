# Experiment: TFT Helper Manual Snapshot

## Summary
Added a new assistant mode called `TFT Coach` so Clicky can answer with TFT-focused guidance using a local patch/meta snapshot that is manually refreshed.

## What Changed
- Added assistant mode selection in the menu bar panel (`General` vs `TFT Coach`).
- Added a local TFT snapshot source in `TFTMetaContext.swift`.
- Appended TFT-specific instructions + snapshot context into the Claude system prompt when `TFT Coach` mode is active.
- Added panel status text so users can see which snapshot is currently loaded.
- Added analytics event for mode switching (`assistant_mode_selected`).
- Added `scripts/update_tft_meta_snapshot.py` to refresh the hardcoded snapshot when new patch notes release.
- Added tests for TFT prompt context/status builders.

## Why
The app previously had only a generic assistant prompt. Even with a TFT-looking screen, it had no stable, patch-aware TFT context and no dedicated behavior mode.

## Root Cause
- No domain mode switch existed in `CompanionManager`/`CompanionPanelView`.
- No local data source existed for current TFT patch/meta context.
- No maintenance workflow existed for patch refreshes.

## What Was Tried and Rejected
- Initial direction was a live worker endpoint for TFT meta data.
- Rejected per request to keep this hardcoded/local for now and manually updated per patch.

## Key Files
- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/CompanionPanelView.swift`
- `leanring-buddy/TFTMetaContext.swift`
- `leanring-buddy/ClickyAnalytics.swift`
- `leanring-buddyTests/leanring_buddyTests.swift`
- `scripts/update_tft_meta_snapshot.py`

## Gotchas
- Auto patch discovery from the en-us tag page may lag or differ by locale. Use `--patch-url` when needed:
  - `python3 scripts/update_tft_meta_snapshot.py --patch-url <official-patch-url>`
- Snapshot is intentionally manual. If this file is stale, coach quality will drift.
- This is not live ladder ingestion; recommendations still depend on screenshot state.

## Verified Live Surface
- Exact route used: macOS menu bar panel (`NSStatusItem` -> `CompanionPanelView`), no web route.
- Files that render it:
  - `leanring-buddy/CompanionPanelView.swift`
- Code path that reaches it:
  - `leanring_buddyApp.swift` -> `CompanionAppDelegate` -> `MenuBarPanelManager` -> `CompanionPanelView`
- Stale routes intentionally not touched:
  - No old/duplicate web routes exist (menu bar app only).

## Verification
Within 5 minutes, confirm with these checks:

1. UI mode visibility
- Launch app, open panel.
- Confirm `Mode` segmented control appears with `General` and `TFT Coach`.
- Switch to `TFT Coach`.
- Confirm the status line appears: `Manual TFT snapshot: ...`.

2. Prompt context instrumentation
- Trigger push-to-talk once in `TFT Coach`.
- Check app logs for structured prompt context event:
  - grep pattern: `"event":"clicky_prompt_context"`
  - expected fields include:
    - `"assistantMode":"tft_coach"`
    - `"transcriptCharacterCount":<number>`

3. Analytics signal
- In PostHog, verify event `assistant_mode_selected` is emitted with property `mode=tft_coach` and `mode=general`.

4. Snapshot refresh script
- Run:
  - `python3 scripts/update_tft_meta_snapshot.py`
- Confirm `leanring-buddy/TFTMetaContext.swift` snapshot block updates between markers:
  - `// BEGIN_AUTOGEN_TFT_SNAPSHOT`
  - `// END_AUTOGEN_TFT_SNAPSHOT`

5. Unit test coverage
- Confirm tests exist for TFT prompt context/status builder in:
  - `leanring-buddyTests/leanring_buddyTests.swift`
