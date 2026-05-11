# vibe-id changes needed

Schema/handler changes that need to land in the vibe-id repo
(`github.com/Clamepending/vibe-id`). Apply once, then this file can be
emptied/removed.

---

## Forward `anthropic-beta` header on `/chat`

**Why:** Dot now declares Anthropic's predefined memory tool
(`memory_20250818`) in its tool-use requests. Anthropic gates that tool
behind the `anthropic-beta: context-management-2025-06-27` header, which
the macOS app sets on every `runAgentTurnWithToolUse` request
(`leanring-buddy/ClaudeAPI.swift`). If the proxy doesn't forward the
header upstream, the API will reject the request with a 400 (unknown
tool type).

**Change:** in vibe-id's `/chat` handler, when proxying to
`api.anthropic.com/v1/messages`, copy the incoming
`anthropic-beta` request header through to the upstream fetch. If the
handler currently builds the upstream request from an allowlist, add
`anthropic-beta` to the allowlist; if it forwards all headers, this
already works.

**Verification:** after deploying, hit `/chat` from the macOS app and
confirm the response is a normal tool-use turn (not a 400). The first
successful turn that issues a memory tool call will surface in the app's
debug log as `memory.tool: memory command requested`.

**Quota/cost note:** the memory tool's `view`/`create`/`str_replace`/etc.
calls bill as ordinary tool-use tokens — no separate budget needed in
vibe-id. File storage is local to each Dot install
(`~/Library/Application Support/Dot/memories/`), so no D1 schema
changes either.
