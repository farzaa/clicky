# Background Agent Tasks: Dot as a Conductor for External Coding Agents

Status: **Initial design — v1 implementation in progress.**

## Goal

Let the user say things like *"hey dot, reimplement this paper and give me an interactive demo"* and have Dot run that as a long-lived background task on the user's Mac — without competing with Claude Code / Codex CLI's coding ability.

Dot's edge is voice + screen + ambient surface. We use that to orchestrate existing best-in-class coding agents rather than reimplementing them.

## Non-goals (v1)

- Cloud execution. Tasks run on the user's machine.
- Multiple concurrent agent tasks. One at a time; queue further requests.
- Existing-repo edits driven by frontmost-IDE detection. v1 only spawns greenfield work into auto-named directories.
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
│   ↓ AgentTaskPlanner.classifyAndPlan(transcript)     │
│   │     ↳ uses Claude inline to turn the spoken      │
│   │       request into a structured brief            │
│   ↓                                                  │
│   ↓ inline? → existing tool-use loop                 │
│   ↓ background? → AgentTaskManager.startTask(brief)  │
│                                                      │
│  AgentTaskManager (single-task v1)                   │
│   - owns AgentTask state + history                   │
│   - holds one AgentWorker subprocess                 │
│   - feeds AgentTaskEvent stream into the panel       │
│                                                      │
│  AgentTaskPanelManager  →  NSPanel on right edge     │
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

What the user wants, expanded into something a coding agent can act on. Produced by `AgentTaskPlanner` from the raw transcript + an optional screenshot.

```swift
struct AgentTaskBrief {
    let taskID: UUID
    let oneLineTitle: String                  // panel header
    let userOriginalRequest: String           // verbatim transcript
    let detailedInstructions: String          // the actual prompt to the worker
    let workingDirectoryURL: URL              // auto-named, e.g. ~/Desktop/Dot Tasks/...
    let estimatedDurationDescription: String  // "about 10 minutes" — surfaced via TTS
    let maxToolCallSteps: Int                 // budget cap, default 75
    let maxWallClockSeconds: Int              // budget cap, default 1800
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
       --permission-mode=acceptEdits \
       --cwd <workingDirectoryURL> \
       <<<"<one-shot brief>"
```

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

## AgentTaskPlanner — voice request → brief

The planner uses Dot's existing `ClaudeAPI` (vibe-id-proxied Anthropic) with a small prompt that returns structured JSON:

```json
{
  "routeDecision": "background",  // or "inline"
  "oneLineTitle": "Reimplement attention paper",
  "detailedInstructions": "Read the PDF in the user's current screen if accessible. Set up a Python venv with PyTorch and Gradio. Implement the model from section 3. Smoke-train on synthetic data for under 5 minutes. Build a Gradio demo and print the local URL.",
  "estimatedDuration": "about 10 minutes"
}
```

If `routeDecision=="inline"`, we fall through to the existing inline tool-use loop. If `"background"`, we hand the brief to `AgentTaskManager`.

The classifier prompt is small enough (~300 tokens) that the latency hit is acceptable on every transcript. We don't try to be clever with prefix shortcuts in v1 — the LLM is the router.

The working directory is auto-named from `oneLineTitle` → slug + date, placed under `~/Desktop/Dot Tasks/<slug>-<yyyy-mm-dd>/`. Auto-`git init` and create an `INSTRUCTIONS.md` file with the brief inside it before spawning, so the agent sees its own marching orders on disk.

## AgentTaskManager — lifecycle + single-task semantics

```swift
@MainActor
final class AgentTaskManager: ObservableObject {
    @Published private(set) var currentTask: AgentTask?
    @Published private(set) var recentlyCompletedTasks: [AgentTask] = []
    // single task at a time for v1; further requests get rejected with TTS

    func startTask(brief: AgentTaskBrief) async
    func cancelCurrentTask() async
    func sendFollowUpToCurrentTask(_ message: String) async
}
```

`AgentTask` is a value type holding the brief + an ordered list of received events + status (`queued | running | completed | failed | cancelled`).

If a second task is requested while one is running, v1 rejects it via TTS: *"I'm still working on the previous task. Say 'cancel that' if you want me to stop it."*

## Right-side panel

A new `NSPanel`, mirroring `MenuBarPanelManager`:

- 380pt wide, anchored to the right edge of the primary screen
- Same nonactivating / floating / canJoinAllSpaces / fullScreenAuxiliary attributes as the menu bar panel
- Auto-shows when a task starts; auto-hides 5s after the last task completes (unless user pinned it)
- Content: SwiftUI `AgentTaskPanelView` listing the current task (title, status badge, expandable event log, cancel button, reveal-in-Finder button) and recent completions

Visual style follows `DS` design system tokens.

## Trigger flow end-to-end

1. User holds push-to-talk, says *"hey dot, reimplement the paper on my screen and give me an interactive demo."*
2. Existing dictation pipeline finalizes the transcript on key-up.
3. `handleDirectLocalMediaCommandIfRecognized` returns false (no match).
4. **New**: `AgentTaskPlanner.classifyAndPlan(transcript:, screenContext:)` runs.
5. Planner returns `routeDecision == "background"` with a structured brief.
6. `CompanionManager` calls `agentTaskManager.startTask(brief:)`.
7. `AgentTaskManager` creates the working dir, `git init`s, writes `INSTRUCTIONS.md`, and asks `ClaudeCodeAdapter.spawn(brief:)`.
8. `AgentTaskPanelManager` shows the right-side panel.
9. Events stream in. Each `assistantMessage` event optionally goes to TTS for the *first* one only — subsequent messages go to the panel silently to avoid TTS-spam during a 10-minute task.
10. On `workerCompleted`, Dot speaks one summary line and posts a macOS notification.

Mid-run voice interrupt:
- User holds push-to-talk again, says *"actually use JAX instead of PyTorch."*
- Dictation pipeline finalizes.
- `CompanionManager` detects an active task in `AgentTaskManager` and routes the new transcript via `agentTaskManager.sendFollowUpToCurrentTask(_)` instead of starting a new task or running inline.
- `ClaudeCodeAdapter.sendFollowUpMessage` writes a user message line to the process's stdin.

## Budgets + guardrails

- Step budget (`maxToolCallSteps`): default 75. Worker self-honors via Claude Code's `--max-turns`.
- Wall clock (`maxWallClockSeconds`): default 1800 (30 min). Enforced by a `Task.sleep` cancellation watchdog in `AgentTaskManager`.
- Working dir is always under `~/Desktop/Dot Tasks/`. No tasks ever operate on system directories or the user's home root.
- `--permission-mode=acceptEdits` is the default. We do NOT pass `--dangerously-skip-permissions`.
- Auto-`git init` + commit before spawning, so the user can `git diff` / `git reset --hard` to roll the whole task back.

## Risks

1. **Claude Code not installed.** Mitigation: detect, surface "install Claude Code" UI + spoken hint. Don't try to install it automatically.
2. **stream-json schema drift.** Mitigation: keep the adapter thin (~400 LOC), version-check Claude Code at startup and warn if older than a known-good version, ignore unknown event types rather than crashing.
3. **Stuck/runaway tasks.** Mitigation: step + wall-clock budgets, panel-visible cancel button, mid-run voice interrupt.
4. **Authentication is the user's responsibility in v1.** If the user hasn't logged into Claude Code (`claude` CLI), the subprocess will fail at startup. We detect this from the failure event and surface "Sign in to Claude Code in Terminal first" in the panel. v2 will offer `ANTHROPIC_BASE_URL` pointed at vibe-id for users who don't want to manage their own auth.
5. **Cost.** With user-owned Claude Code auth, the user pays Anthropic directly — Dot doesn't burn vibe-id quota. v2's vibe-id passthrough will need per-task spend caps.

## What ships in v1

- `AgentTaskBrief`, `AgentTaskEvent`, `AgentWorker` protocol, `AgentTask`
- `ClaudeCodeAdapter` (only worker)
- `AgentTaskManager` (single concurrent task)
- `AgentTaskPlanner` (LLM-based classification + brief expansion)
- `AgentTaskPanelManager` + `AgentTaskPanelView`
- `CompanionManager` integration at the transcript-submit point
- Auto-`git init` of working dirs
- Cancel + reveal-in-Finder

## What's explicitly deferred

- Codex CLI adapter
- Multiple concurrent tasks
- Existing-repo (frontmost-IDE-detected) cwd
- Vibe-id Anthropic passthrough
- Local Swift fallback worker
- Streaming partial assistant tokens to TTS mid-run (instead of one summary line)
- Persistent task history across app restarts
- Inline pause/resume via voice
