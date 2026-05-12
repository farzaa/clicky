# Background Agent Tasks: Dot as a Conductor for External Coding Agents

Status: **Implemented explicit-prefix background coding agents.**

## Goal

Let the user explicitly say things like *"dot agent reimplement this paper and give me an interactive demo"* and have Dot run that as a long-lived background coding task on the user's Mac. Non-prefixed requests stay in Dot's normal live computer-use loop.

Dot's edge is voice + screen + ambient surface. We use that to orchestrate existing best-in-class coding agents rather than reimplementing them.

## Non-goals (v1)

- Cloud execution. Tasks run on the user's machine.
- Broad live browser/app automation in background agents. Normal Dot handles UI/session work inline.
- Existing-repo cwd inference from frontmost IDEs. v1 uses auto-named task directories and tells the worker to inspect user-supplied paths when possible.
- Vibe-id Anthropic passthrough. v1 uses the user's installed Claude Code CLI auth.
- Codex CLI fallback. v1 ships Claude Code support only; the adapter protocol is shaped so adding Codex is a single new file in v2.
- A local in-process Swift agent loop as a fallback. v1 surfaces "install Claude Code" if not present.

## High-level shape

```
┌──────────────────────────────────────────────────────┐
│  Dot (Swift, on-device)                              │
│                                                      │
│  CompanionManager                                    │
│   ↓ transcript finalized                             │
│   ↓ explicit prefix check                            │
│   │     ↳ dot agent prefix spawns                    │
│   ↓                                                  │
│   ↓ no route → existing live inline tool-use loop    │
│   ↓ background route → AgentTaskManager.startTask    │
│                                                      │
│  AgentTaskManager (multi-task coding agents)         │
│   - owns AgentTask state + history                   │
│   - holds one AgentWorker subprocess                 │
│   - feeds AgentTaskEvent stream into the panel       │
│                                                      │
│  SubagentDotOverlayManager → colored right-edge dots │
│  AgentTaskPanelManager    → selected-task NSPanel    │
│   - SwiftUI view: title, status, event log, cancel   │
└──────────────────────────────────────────────────────┘
                        │
                        ▼  spawn subprocess + stream-json IPC
┌──────────────────────────────────────────────────────┐
│  Claude Code CLI (or future: Codex CLI, etc.)        │
│  Executes in a per-task working directory.           │
└──────────────────────────────────────────────────────┘
```

The boundary that matters is **the `AgentWorker` protocol**. Everything above it is our Swift code; everything below is someone else's. Get the protocol right and we can swap workers without touching the orchestration or UI layers.

## Core types

### `AgentTaskBrief`

What the user wants, converted from an explicit `dot agent ...` command into something a background agent can act on.

```swift
struct AgentTaskBrief {
    let taskID: UUID
    let oneLineTitle: String                  // panel header
    let userOriginalRequest: String           // verbatim transcript
    let detailedInstructions: String          // the actual prompt to the worker
    let workingDirectoryURL: URL              // auto-named, e.g. ~/Desktop/Dot Tasks/...
    let additionalDirectoryURLs: [URL]        // explicit user-supplied paths exposed through --add-dir
    let estimatedDurationDescription: String  // "about 10 minutes" — surfaced via TTS
    let maxToolCallSteps: Int                 // budget cap, default 120
    let maxWallClockSeconds: Int              // budget cap, default 2700
}
```

### `AgentTaskEvent`

The unit of progress the worker emits, mapped from whatever native event stream the underlying agent produces.

```swift
enum AgentTaskEvent {
    case workerStarted(workerDisplayName: String)
    case plannerPhase(description: String)        // "thinking", "starting"
    case assistantMessage(text: String)
    case toolCallInvoked(name: String, oneLineSummary: String)
    case fileEdit(filePath: URL, summaryDiff: String?)
    case shellCommand(command: String, output: String?)
    case warningEmitted(text: String)
    case errorRaised(text: String)
    case workerCompleted(finalSummary: String)
    case workerFailed(failureReason: String)
    case workerCancelled
}
```

### `AgentWorker` protocol

```swift
protocol AgentWorker: AnyObject {
    static var displayName: String { get }
    static func isInstalledOnSystem() async -> Bool
    static func installInstructionMessage() -> String  // user-facing if not installed

    func spawn(brief: AgentTaskBrief) async throws
        -> AsyncThrowingStream<AgentTaskEvent, Error>

    func sendFollowUpMessage(_ message: String) async throws  // mid-run voice interrupt
    func cancel() async
}
```

v1 implements `ClaudeCodeAdapter: AgentWorker`. Codex/Aider are deferred.

## ClaudeCodeAdapter — the actual integration

We invoke Claude Code as:

```bash
claude -p --output-format=stream-json --input-format=stream-json \
       --permission-mode=bypassPermissions \
       --allowedTools <comma-separated allowlist> \
       --max-turns <brief.maxToolCallSteps> \
       <<<"<one-shot brief>"
```

Explicit coding tasks get code/search/shell tools and stay headless. Browser/app UI work remains in Dot's live inline loop.

We read stdout line-by-line; each line is a JSON object of the form:

```json
{"type": "assistant", "message": {"content": [...]}}
{"type": "user",      "message": {"content": [{"type": "tool_result", ...}]}}
{"type": "system",    "subtype": "init", ...}
{"type": "result",    "subtype": "success", ...}
```

Mapping to `AgentTaskEvent`:

- `system.init` → `workerStarted`
- `assistant.message.content[].type=="text"` → `assistantMessage`
- `assistant.message.content[].type=="tool_use"` → `toolCallInvoked`, with `name` like `Edit`, `Bash`, `Write`, `Read` and a one-line summary derived from `input`
- `user.message.content[].type=="tool_result"` with `is_error=true` → `warningEmitted`
- `result.subtype=="success"` → `workerCompleted(finalSummary: result.result)`
- `result.subtype=="error_max_turns" | "error_during_execution"` → `workerFailed`

Mid-run follow-up: write `{"type":"user","message":{"role":"user","content":"<text>"}}\n` to the process's stdin. Claude Code's stream-json input mode reads this as a follow-up turn.

Cancellation: send SIGTERM; if still alive after 2s, SIGKILL.

Detection: `which claude || command -v claude || stat ~/.npm-global/bin/claude /opt/homebrew/bin/claude /usr/local/bin/claude`. Memoize. If absent, the manager surfaces "install Claude Code" in the panel and a TTS line.

## Explicit command routing

Dot does not use an LLM or keyword classifier to infer background-agent intent. The only background trigger is a leading `dot agent ...` command:

- `submit my homework to the course site` → normal Dot live inline loop
- `click the save button in Chrome` → normal Dot live inline loop
- `dot agent build me a CS185 test harness` -> background agent
- `dot agent inspect /Users/mark/Desktop/project and summarize failing tests` -> background agent

The prefix is intentionally blunt. It gives the user a reliable mental model and prevents long-running coding agents from appearing when the user expected Dot to operate the current browser/app session.

If the stripped request contains existing absolute or `~/...` paths, Dot adds those directories to Claude Code with `--add-dir`. Generated task state still lives under `~/Desktop/Dot Tasks/`, but explicit paths let the worker inspect real project folders without requiring a live UI route.

The working directory is auto-named from `oneLineTitle` → slug + date, placed under `~/Desktop/Dot Tasks/<slug>-<yyyy-mm-dd>/`. Auto-`git init` and create an `INSTRUCTIONS.md` file with the brief inside it before spawning, so the agent sees its own marching orders on disk.

## AgentTaskManager — lifecycle + multi-task semantics

```swift
@MainActor
final class AgentTaskManager: ObservableObject {
    @Published private(set) var runningTasks: [AgentTask] = []
    @Published private(set) var recentlyFinishedTasks: [AgentTask] = []
    // up to 5 concurrent coding agents; further requests get rejected with TTS

    func startTask(brief: AgentTaskBrief) async
    func cancelMostRecentRunningTask() async
    func cancelTask(taskID: UUID) async
    func deleteTask(taskID: UUID) async
}
```

`AgentTask` is an `ObservableObject` reference type holding the brief + an ordered list of received events + status (`queued | running | completed | failed | cancelled`).

Each running task owns a separate `ClaudeCodeAdapter`, event-consumer task, and wall-clock watchdog keyed by task ID. If a sixth task is requested while five are running, Dot rejects it via TTS and asks the user to cancel one before starting another.

Deleting a subagent removes it from Dot's `runningTasks` / `recentlyFinishedTasks` UI state. If the subagent is still running, deletion cancels its `ClaudeCodeAdapter` first. The working directory is never deleted by this action.

## Right-side dots and panel

Two `NSPanel` surfaces mirror the `MenuBarPanelManager` style:

- `SubagentDotOverlayManager`: transparent right-edge overlay, one colored clickable dot per running/recent task, stacked from top right downward
- `AgentTaskPanelManager`: 380pt selected-task detail panel opened by clicking a dot
- Same nonactivating / floating / canJoinAllSpaces / fullScreenAuxiliary attributes as the menu bar panel
- The dot overlay appears when tasks exist; the detail panel does not auto-open
- Hovering a dot reveals an `x` delete control; destructive deletion stays on the dot overlay instead of being duplicated in the detail panel
- Content: SwiftUI `AgentTaskPanelView` showing the selected task's title, status badge, latest assistant summary, collapsed-by-default event history, and a cancel action for running tasks

Visual style follows `DS` design system tokens.

## Trigger flow end-to-end

1. User holds push-to-talk, says *"dot agent reimplement the paper and give me an interactive demo."*
2. Existing dictation pipeline finalizes the transcript on key-up.
3. `handleDirectLocalMediaCommandIfRecognized` returns false (no match).
4. `CompanionManager` detects the explicit `dot agent` prefix.
5. `CompanionManager` captures best-effort foreground page/PDF/document context, preferring the Accessibility document reference for content extraction when it differs from a stale browser URL.
6. `CompanionManager` builds an `AgentTaskBrief` directly from the stripped request and captured context. If a text excerpt was captured, the worker is told to use it directly instead of refetching localhost/private/file/app-internal URLs.
7. `AgentTaskManager` creates the working dir, `git init`s, writes `INSTRUCTIONS.md`, and asks `ClaudeCodeAdapter.spawn(brief:)`.
8. `SubagentDotOverlayManager` shows a colored dot for the new coding agent.
9. User clicks a dot to open `AgentTaskPanelManager` for that task's output.
10. Events stream in. Each `assistantMessage` event optionally goes to TTS for the *first* one only — subsequent messages go to the panel silently to avoid TTS-spam during a 10-minute task.
11. On `workerCompleted`, Dot speaks one summary line and posts a macOS notification.

Mid-run voice interrupt:
- User holds push-to-talk again, says *"actually use JAX instead of PyTorch."*
- Dictation pipeline finalizes.
- Short cancellation phrases cancel the most recent running background agent.
- Other non-prefixed transcripts stay in the normal Dot inline loop. Background follow-up routing is intentionally deferred until there is an explicit UI or command syntax for choosing the target agent.

## Budgets + guardrails

- Step budget (`maxToolCallSteps`): default 120. Worker self-honors via Claude Code's `--max-turns`.
- Wall clock (`maxWallClockSeconds`): default 2700 (45 min). Enforced by a `Task.sleep` cancellation watchdog in `AgentTaskManager`.
- Generated task state is always under `~/Desktop/Dot Tasks/`. Workers may inspect or edit user-supplied paths when Claude Code permissions allow it; if access is blocked, the worker should report the exact path and blocker.
- `--permission-mode=bypassPermissions` and an explicit allowed-tool set are used for background agents so they do not block on invisible approval prompts.
- Explicit coding agents get headless code/search/shell tools only.
- Auto-`git init` before spawning, so the generated task directory has rollback affordance through ordinary git commands.

## Risks

1. **Claude Code not installed.** Mitigation: detect, surface "install Claude Code" UI + spoken hint. Don't try to install it automatically.
2. **stream-json schema drift.** Mitigation: keep the adapter thin (~400 LOC), version-check Claude Code at startup and warn if older than a known-good version, ignore unknown event types rather than crashing.
3. **Stuck/runaway tasks.** Mitigation: step + wall-clock budgets, panel-visible cancel button, mid-run voice interrupt.
4. **Authentication is the user's responsibility in v1.** If the user hasn't logged into Claude Code (`claude` CLI), the subprocess will fail at startup. We detect this from the failure event and surface "Sign in to Claude Code in Terminal first" in the panel. v2 will offer `ANTHROPIC_BASE_URL` pointed at vibe-id for users who don't want to manage their own auth.
5. **Cost.** With user-owned Claude Code auth, the user pays Anthropic directly — Dot doesn't burn vibe-id quota. v2's vibe-id passthrough will need per-task spend caps.

## What ships in v1

- `AgentTaskBrief`, `AgentTaskEvent`, `AgentWorker` protocol, `AgentTask`
- `ClaudeCodeAdapter` (only worker)
- `AgentTaskManager` (up to 5 concurrent coding agents)
- `SubagentDotOverlayManager` + `SubagentDotOverlayView`
- `AgentTaskPanelManager` + `AgentTaskPanelView`
- `CompanionManager` explicit `dot agent ...` command routing
- Auto-`git init` of working dirs
- Right-edge dot deletion + running-task cancel

## What's explicitly deferred

- Codex CLI adapter
- Existing-repo (frontmost-IDE-detected) cwd
- Vibe-id Anthropic passthrough
- Local Swift fallback worker
- Streaming partial assistant tokens to TTS mid-run (instead of one summary line)
- Persistent task history across app restarts
- Inline pause/resume/follow-up via voice
