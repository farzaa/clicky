# Agent Loop Migration: Text Tags → Anthropic Tool Use

Status: **Migration complete.** All six stages landed in a single sweep. The text-tag agent loop, parser, and feature flag have been deleted; the tool-use protocol is now the only agent loop. Prompt caching enabled on the static prefix (system + tool schemas). Smoke-tested end-to-end with `navigate_browser`, `open_new_tab`, multi-step chaining, the `bail_out` escape hatch, and the per-step narration queue.

## Why move off text tags

The current protocol (Claude returns prose with embedded `[CLICK:x,y]`, `[TYPE:...]`, `[NAVIGATE:url]` tags that we regex out) works but is accumulating tech debt:

1. **Parsing is brittle.** Six regex passes against prose. `[TYPE:hello [world]]` would already break the regex; we are one Claude formatting quirk away from a silent bug.
2. **TTS extraction is implicit.** We strip tags and hope the remainder is a coherent sentence. When Claude writes *"your search query is [TYPE:hello]"*, the stripped text is *"your search query is"* — awkward.
3. **No structured contract.** The 70-line "computer control" section of the system prompt IS the contract, and the model occasionally misreads it (in testing, Claude flip-flopped between [NAVIGATE], cmd+L primitives, and click+type within a single turn).
4. **No structured returns.** Actions can't return data. A `find_element_by_label` tool could return coordinates; with tags this would need an extra screenshot round-trip.
5. **No native multi-turn.** Multi-step is faked with a continuation placeholder prompt. Tool use makes multi-turn intrinsic — model emits tool calls, controller sends tool_results back, model continues until it returns text only.

## Target protocol

Tools defined via Anthropic Messages API `tools` parameter, one tool per primitive action:

```
point_at_element(x: int, y: int, label?: string, screen?: int)
click_element(x: int, y: int, label?: string, screen?: int)
type_text(text: string)
press_keystroke(spec: string)
navigate_browser(url: string)
open_new_tab(url?: string)
close_tab()
switch_tab(index: int)
browser_back()
browser_forward()
media_control(command: "play_pause"|"next"|"previous")
bail_out(reason: string)
```

Per turn:
1. Send screenshot + transcript + `tools`.
2. Claude returns content blocks: zero or more `text` blocks (narration → TTS), zero or more `tool_use` blocks (actions → execute).
3. Execute each tool, collect `tool_result` content blocks.
4. Send tool_results + new screenshot back as the next user message.
5. Claude responds again; loop until response has no `tool_use` → task done.

The termination condition maps 1:1 to today's "no action tags → done". Per-step TTS reads the `text` blocks verbatim — no stripping. `[POINT:none]` disappears: *not calling* the point tool IS the no-point state.

## What changes in our code

| Layer | Today | Tool-use |
|---|---|---|
| System prompt | 70-line tag manual + examples | ~20 lines of orientation; tool descriptions ARE the contract |
| Request build | Single user message w/ images + text | `tools` array + multi-turn `messages` |
| Response parse | 6 regex passes | Walk JSON content blocks |
| TTS extract | Strip tags, hope | Text blocks verbatim |
| Action exec | Switch over enum | Same enum; tool_use blocks decode into it |
| Continuation prompt | Hand-rolled placeholder | API-native (tool_result message) |

## Staged migration

- ✅ **Stage 0:** Phase 1 (higher-level browser tags) shipped first to validate the higher-action-level direction.
- ✅ **Stage 1:** Feature flag `DotUseToolUseProtocol` in Info.plist + `AppBundleConfiguration.isToolUseAgentProtocolEnabled()`. Both code paths coexisted during validation.
- ✅ **Stage 2:** `AgentToolDefinitions.swift` defines twelve tool schemas with JSON-Schema inputs and a typed `AgentToolCall` decode layer.
- ✅ **Stage 3:** `ClaudeAPI.runAgentTurnWithToolUse(...)` + `CompanionManager.sendTranscriptToClaudeWithScreenshot(...)` (the tool-use loop became the canonical method during Stage 6). Reuses the existing `CompanionComputerControlAction` executor.
- ✅ **Stage 4:** A/B test against the legacy text-tag path on the same transcript (`navigate to youtube.com`) — both completed the navigation; tool-use produced richer narration via text content blocks.
- ✅ **Stage 5:** Default flag on. Tag protocol kept temporarily as fallback.
- ✅ **Stage 6:** Deleted: legacy agent-loop method (~270 lines), legacy system prompt (~100 lines), `parseComputerControlActions` and `parsePointingCoordinates`-from-tag struct types, dispatch routing, feature flag, and Info.plist key. `parsePointingCoordinates` itself is retained because the onboarding-demo pointing flow uses a simpler text-tag pattern unrelated to the agent loop.

## Design decisions

**Don't use Anthropic's built-in `computer` tool.** Designed for Linux/Docker VMs, hosted compute (cost + latency), doesn't speak our specific abstractions (`navigate_browser`, `media_control`). Define our own tools — same API mechanism, schemas match our actual primitives.

**Drop `[POINT:none]` during migration.** *Not calling* the point tool IS the no-point state. Removing the sentinel cleans up both prompt and executor.

**Keep narration in text blocks, not as a separate tool.** Text blocks are the natural channel.

**Add `bail_out(reason)` as a new tool.** Today Claude has no way to say "I'm stuck" — it has to retry or end the loop silently. An explicit bail tool gives the loop a clean escalation and gives Claude a clean way to surface stuckness.

**Non-streaming for tool use.** Streaming text + tool_use deltas is more complex (separate SSE event types). For stage 1, use the non-streaming variant — we already gate the TTS until after action parsing anyway, so no UX regression.

**Multi-turn message accumulation lives in `CompanionManager`.** `ClaudeAPI` just sends one request and parses one response; the agent loop owns the message list.

## Risks + mitigations

1. **Cost increase from multi-turn tool_results** → token count grows each step. Mitigate via prompt caching of system + tools (deferred to a follow-up; first prove correctness).
2. **Model behavior shift** → Claude on tool use may use tools differently than tags. Stage 4 A/B with the same transcripts; compare action sequences before flipping the default.
3. **TTS timing changes** if Claude reorders text vs tool_use blocks → prompt says: *respond with one short narration text block first, then your tool calls*. Validate in stage 4.
4. **Schema validation rejection** of malformed tool calls → tool runner returns `tool_result { is_error: true }` so Claude can self-correct rather than crash the loop.
5. **Migration window code complexity** → tight stage timeline (1–6 in ~2 weeks). Don't let both protocols coexist for months.

## Open questions

1. **`bail_out` UX** — does it post a UI banner, log only, or trigger an audible "I'm stuck" voice line? Initial: log + speak a brief fallback.
2. **`wait_for_page_load(max_ms)` tool** — give Claude explicit timing control instead of the hardcoded 1.5s post-NAVIGATE. Probably yes in stage 4.
3. **Parallel tool execution** — if Claude returns `[click(a), click(b)]`, run in order vs in parallel. Default to in-order (matches model intent). Defer optimization.
4. **Re-screenshot every step** vs only after visibly-screen-changing actions — marginal token win, adds complexity. Defer.

## Reference: turn structure

Initial user message:
```json
{
  "role": "user",
  "content": [
    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}},
    {"type": "text", "text": "<transcript>"}
  ]
}
```

Assistant response (echoed back into the messages list on next request):
```json
{
  "role": "assistant",
  "content": [
    {"type": "text", "text": "going to drive"},
    {"type": "tool_use", "id": "toolu_abc", "name": "navigate_browser", "input": {"url": "drive.google.com"}}
  ]
}
```

User follow-up:
```json
{
  "role": "user",
  "content": [
    {"type": "tool_result", "tool_use_id": "toolu_abc", "content": "ok"},
    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}}
  ]
}
```

Repeat until assistant returns no `tool_use` blocks → done.
