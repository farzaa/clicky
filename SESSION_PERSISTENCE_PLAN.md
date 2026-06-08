# Session Persistence — Implementation Plan

**Branch:** `feature/session-persistence`
**Worktree:** `/Users/cristeaoctavian/Projects/clicky-session-persistence`
**Data home (isolated):** `/tmp/clicky-session-persistence`
**Scope:** Step 1 of the memory pipeline only — **sessions get saved to disk correctly.** Do NOT build the gate, distill, or consent steps here. Keep this PR small and reviewable.

Reference: [`docs/architecture/MEMORY_PIPELINE.md`](docs/architecture/MEMORY_PIPELINE.md) (esp. "Session boundary" and "Capture" sections) and [`docs/architecture/schemas/session.example.json`](docs/architecture/schemas/session.example.json).

---

## Why this is first

Today sessions live only in RAM as `CompanionManager.sessionTrace` (`[SessionTraceEntry]`, capped at 20 entries, and **wiped** by `maybeWriteTeachingSkill` on a successful skill write — see `CompanionManager.swift:377`). The downstream gate/distill/consent steps all need a saved session JSON to operate on. Nothing downstream can exist without this.

---

## Context: existing code you will build on

| Thing | Location | Notes |
|-------|----------|-------|
| `SessionTraceEntry` | `leanring-buddy/TeachingSkill.swift:326` | `timestamp: Date`, `userTranscript: String`, `assistantResponse: String`, `bundleId: String?`, `pointed: Bool`. Currently `Equatable` only — **add `Codable`**. |
| In-RAM trace | `CompanionManager.swift:85` | `private var sessionTrace: [SessionTraceEntry] = []` |
| Capture hook | `CompanionManager.swift:284` `recordSessionExchange(...)` | Appends a turn; caps at 20; records topic history. Called at `CompanionManager.swift:1100`. |
| Skill-write hook | `CompanionManager.swift:312` `maybeWriteTeachingSkill(after:)` | Called at `CompanionManager.swift:1105`, right after `recordSessionExchange`. On success it calls `sessionTrace.removeAll()` at line 377. **This is the wipe you must persist ahead of.** |
| Confirmation detection | `SkillTriggerEvaluator.isConfirmationTranscript(_:)` | Already exists. Reuse for the confirm-phrase session-end trigger. |
| Screen-teaching detection | `SkillTriggerEvaluator.isScreenTeachingSession(_:)` | Reuse if needed for outcome heuristics. |
| Isolated paths | `leanring-buddy/ClickyPaths.swift` | `ClickyPaths.home` (already worktree-isolated via `CLICKY_HOME`). Add a `sessions` URL here. |
| Path tests pattern | `leanring-buddyTests/ClickyPathsTests.swift` | Uses `ClickyPaths.overrideHomeForTesting`. Mirror this for `SessionStore` round-trip tests. |
| Panel close hook | `MenuBarPanelManager.swift:143` `hidePanel()` + `.clickyDismissPanel` notification (`MenuBarPanelManager.swift:17`) | Use to detect "panel closed" session boundary. |
| Launch lifecycle | `CompanionManager.swift:454` `start()` → `bootstrapTeachingSkills()` (`:257`) | Add the 7-day cleanup call here. |
| Learning toggle | `CompanionManager.isLearningFromSessionsEnabled` (`:93`) | Respect it. When disabled, treat the session as `privacyOptOut = true` (still persist, but flagged) — see Open Questions. |

**Xcode project note:** the target uses `PBXFileSystemSynchronizedRootGroup`, so any new `.swift` file dropped into `leanring-buddy/` (or `leanring-buddyTests/`) is auto-included in the build. **No `project.pbxproj` editing required.**

**Persistence target path:** `ClickyPaths.home/sessions/<yyyy-MM-dd>/<sessionId>.json` (per MEMORY_PIPELINE.md "Capture" → Persistence). The date folder is the session's `startedAt` in local time.

---

## What to build (4 small steps)

### Step 1 — Model + store

**1a. Make `SessionTraceEntry` `Codable`** (`TeachingSkill.swift:326`).
Change `struct SessionTraceEntry: Equatable` → `struct SessionTraceEntry: Equatable, Codable`. All stored properties are already `Codable`-compatible. This is the only edit to that file.

**1b. New file `leanring-buddy/PersistedSession.swift`** — matches `schemas/session.example.json`:

```swift
struct PersistedSession: Codable, Equatable {
    let sessionId: UUID
    let startedAt: Date
    let endedAt: Date
    let outcome: SessionOutcome
    let privacyOptOut: Bool
    let appsUsed: [String]      // unique bundle IDs, in first-seen order
    let turns: [SessionTraceEntry]
}

enum SessionOutcome: String, Codable {
    case success
    case abandoned
    case unknown
}
```

Notes:
- The schema uses string values `"success" | "abandoned" | "unknown"`; `SessionOutcome: String` serializes to exactly those. Verify the encoder produces the bare string (it does for `RawRepresentable String` enums).
- Dates in the schema are ISO8601 (`2026-06-05T14:22:10Z`). Configure the `JSONEncoder`/`JSONDecoder` in `SessionStore` with `.iso8601` date strategy so output matches the schema (the default `.deferredToDate` emits numeric timestamps — **do not** use the default).

**1c. Add `sessions` path to `ClickyPaths`** (`ClickyPaths.swift`, alongside `skills` / `topicHistory`):

```swift
static var sessions: URL {
    home.appendingPathComponent("sessions", isDirectory: true)
}
```

**1d. New file `leanring-buddy/SessionStore.swift`** — filesystem store, mirror `TeachingSkillStore` style:

```swift
final class SessionStore {
    static var sessionsRootURL: URL { ClickyPaths.sessions }

    @discardableResult
    func save(_ session: PersistedSession) throws -> URL  // writes <root>/<yyyy-MM-dd>/<sessionId>.json
    func deleteSessionsOlderThan(days: Int, now: Date = Date())  // 7-day cleanup
    // (optional helpers) func loadAllSessions() -> [PersistedSession]
}
```

Implementation details:
- Use a dedicated `JSONEncoder` with `dateEncodingStrategy = .iso8601` and `outputFormatting = [.prettyPrinted, .sortedKeys]`.
- Date-folder name: format `startedAt` with a fixed `DateFormatter` (`yyyy-MM-dd`, `Locale(identifier: "en_US_POSIX")`, current time zone). Create intermediate directories.
- Write atomically (`.atomic`).
- `deleteSessionsOlderThan`: walk `sessionsRootURL`, parse each `<yyyy-MM-dd>` folder (or use file modification date as a fallback) and remove folders/files older than the cutoff. Be defensive — never throw out of cleanup; log and continue.

### Step 2 — Session-end detection in `CompanionManager`

The boundary (MEMORY_PIPELINE.md "Session boundary") fires on **any** of:
1. Confirmation phrase on the latest turn — `SkillTriggerEvaluator.isConfirmationTranscript(transcript)`.
2. **30 seconds** idle after the last exchange.
3. Companion panel closed.

Add:
- `private let sessionStore = SessionStore()`
- `private var sessionStartedAt: Date?` — set on the first `recordSessionExchange` of a new session (i.e. when `sessionTrace` was empty before the append).
- `private var sessionIdleTimer: Timer?` — (re)scheduled at 30s on every `recordSessionExchange`; on fire, call `finalizeAndPersistSession(outcome:)`. Must be created/invalidated on the main actor.
- A guard so a session is only persisted once (e.g. set `sessionStartedAt = nil` after finalize, and bail early if there are no turns).

Wire the three triggers:
- **Confirm phrase:** in `recordSessionExchange` (or right after it at `:1100`), if `isConfirmationTranscript(transcript)` is true, finalize with `outcome: .success`.
- **Idle:** the `sessionIdleTimer` callback finalizes with `outcome` derived (see Step 3).
- **Panel close:** observe `.clickyDismissPanel` (or add a hook in `MenuBarPanelManager.hidePanel()`), finalize the in-flight session. Prefer subscribing to the existing `.clickyDismissPanel` notification in `CompanionManager` so `MenuBarPanelManager` stays untouched — but note that notification is also posted during onboarding restart (`triggerOnboarding`), so only finalize when `sessionTrace` is non-empty.

### Step 3 — Finalize + persist

New `private func finalizeAndPersistSession(outcome: SessionOutcome? = nil)`:
1. Guard: `!sessionTrace.isEmpty`, else return (and clear timer/state).
2. Compute `outcome` if not explicitly passed:
   - confirmation phrase seen on any/last turn → `.success`
   - idle/panel-close with at least one `pointed` turn or screen-teaching → `.unknown`
   - otherwise → `.abandoned`
   (Keep this heuristic simple and documented in code comments; it can be refined by the later gate PR.)
3. `appsUsed`: unique `bundleId`s from `sessionTrace.compactMap(\.bundleId)`, preserving first-seen order.
4. `privacyOptOut`: `!isLearningFromSessionsEnabled` (see Open Questions).
5. Build `PersistedSession(sessionId: UUID(), startedAt: sessionStartedAt ?? firstTurnTimestamp, endedAt: Date(), …, turns: sessionTrace)`.
6. `try? sessionStore.save(session)` (log on failure; never crash the voice pipeline).
7. Reset: invalidate `sessionIdleTimer`, `sessionStartedAt = nil`, `sessionTrace.removeAll()`.

**Critical ordering vs. skill write (the line 377 wipe):**
`maybeWriteTeachingSkill` is `async` (spawns `skillWriteTask`) and wipes `sessionTrace` on success. To avoid losing turns:
- **Preferred:** persist the session *before* `maybeWriteTeachingSkill` can wipe it. The simplest correct approach: have the confirm-phrase finalize run at the call site (`:1100`–`:1105`) **before** `maybeWriteTeachingSkill(after:)`, OR snapshot the trace into the `PersistedSession` synchronously at finalize time (finalize takes a value copy of `sessionTrace`, so even if the async task later wipes the live array, the persisted copy is intact).
- Because `finalizeAndPersistSession` copies `sessionTrace` by value into `PersistedSession.turns` synchronously, persistence is safe regardless of the async wipe **as long as finalize runs**. The risk is double-wipe / lost session if only the skill path runs and finalize never fires. Ensure the confirm-phrase path always calls finalize.
- Do not remove or change `maybeWriteTeachingSkill`'s existing behavior. This PR only *adds* persistence.

### Step 4 — 7-day cleanup on launch

In `bootstrapTeachingSkills()` (`CompanionManager.swift:257`) or directly in `start()` (`:454`), add:
```swift
sessionStore.deleteSessionsOlderThan(days: 7)
```
Spec: "Delete after successful distillation or after 7 days." Distill-deletion is out of scope for this PR; only the 7-day sweep is implemented here.

---

## Tests

Add `leanring-buddyTests/SessionStoreTests.swift` (Swift Testing, mirror `ClickyPathsTests.swift`):
- Use `ClickyPaths.overrideHomeForTesting = <temp dir>` with `@Suite(.serialized)` (the override is a shared global — serialize like `ClickyPathsTests`).
- **Round-trip:** save a `PersistedSession` with 2 turns, read the JSON back off disk, decode, `#expect` equality of all fields (including ISO8601 dates and outcome string).
- **Path shape:** assert the file lands at `<home>/sessions/<yyyy-MM-dd>/<sessionId>.json`.
- **JSON shape:** decode the raw file and confirm `outcome` serializes as a bare string and dates are ISO8601 strings (guards against the default numeric date strategy regressing).
- **Cleanup:** create a session folder dated 8 days ago and one dated today; call `deleteSessionsOlderThan(days: 7)`; assert old removed, recent kept.
- Optionally add a `SessionTraceEntry` Codable round-trip test.

Run tests from **Xcode** (Cmd+U) — **do NOT run `xcodebuild` from the terminal** (invalidates TCC permissions per AGENTS.md).

---

## Manual verification

1. Open `/Users/cristeaoctavian/Projects/clicky-session-persistence/leanring-buddy.xcodeproj` in Xcode (this worktree is `--primary`, so push-to-talk is enabled and scheme args set `CLICKY_HOME=/tmp/clicky-session-persistence`).
2. Cmd+R, grant TCC permissions to this build if asked.
3. Do a voice session (push-to-talk), ask something, then say "thanks" / "got it".
4. Confirm a JSON file appears under `/tmp/clicky-session-persistence/sessions/<today>/`, and its contents match the `session.example.json` shape.
5. Test idle path: do an exchange, wait 30s without speaking, confirm a session JSON is written with a non-success outcome.
6. Test panel-close path: do an exchange, click the menu bar icon to close the panel, confirm persistence.

---

## Files touched / added

**Add:**
- `leanring-buddy/PersistedSession.swift`
- `leanring-buddy/SessionStore.swift`
- `leanring-buddyTests/SessionStoreTests.swift`

**Edit:**
- `leanring-buddy/TeachingSkill.swift` — add `Codable` to `SessionTraceEntry` (one line).
- `leanring-buddy/ClickyPaths.swift` — add `sessions` URL.
- `leanring-buddy/CompanionManager.swift` — `sessionStore`, `sessionStartedAt`, `sessionIdleTimer`, session-end triggers, `finalizeAndPersistSession`, 7-day cleanup on launch.

**Docs (per AGENTS.md self-update):**
- Update the "Key Files" table in `AGENTS.md` with `PersistedSession.swift` and `SessionStore.swift`.
- Update `docs/architecture/MEMORY_PIPELINE.md` "Existing code map" — flip "Session persist" from ❌ to ✅.

---

## Scope guardrails (do NOT do here)

- No `MemoryGate`, no distill, no consent UI, no preferences/routines/activity log.
- Do not refactor `maybeWriteTeachingSkill` or `recordSessionExchange` beyond what is needed to hook finalize.
- Do not fix the known non-blocking warnings (Swift 6 concurrency, deprecated `onChange`).
- Do not rename the project/scheme ("leanring" typo is intentional).
- Do not run `xcodebuild` from the terminal.

---

## Open questions (decide, note your choice in the PR)

1. **`privacyOptOut` semantics.** When `isLearningFromSessionsEnabled == false`: (a) persist with `privacyOptOut = true` (recommended — keeps the boundary logic uniform, lets the future gate skip it), or (b) skip persistence entirely. Recommend (a). The MEMORY_PIPELINE "do NOT save when `privacyOptOut`" rule applies at the **gate** stage, not capture.
2. **Multiple end-triggers firing close together** (e.g. confirm phrase then panel close). Guard with `sessionStartedAt == nil` after finalize so only one JSON is written per session.
3. **Outcome heuristic granularity.** Keep it coarse here; the gate PR will refine. Document whatever you pick inline.
