# Personal Vault — On-Demand Retrieval (Implementation Plan)

**Branch / worktree:** `feature/personal-vault` → `/Users/cristeaoctavian/Projects/clicky-personal-vault`  
**Created:** 2026-05-27  
**Related spec:** [`docs/future/personal-vault-knowledge-brain.md`](../future/personal-vault-knowledge-brain.md)

---

## Product decision (this iteration)

**Do not** search or inject vault/brain content on every voice turn.

**Only** when the user explicitly asks for information from their vault or internal knowledge:

1. Detect vault intent from the transcript.
2. Search connected vault + `~/.clicky/brain/` locally.
3. Attach retrieved snippets to **that turn’s user message** (not the standing system prompt).
4. Show panel feedback: “Used 2 notes from Work vault”.

Normal screen-help questions stay unchanged — no vault token cost, no accidental leakage of personal notes into unrelated answers.

---

## UX: Connect vault

```
[Connect vault] in CompanionPanelView
        ↓
VaultDiscoveryService.discoverVaults()
  • Read ~/Library/Application Support/obsidian/obsidian.json
  • Validate paths exist; optional shallow `.obsidian` fallback in ~/Documents, ~/Notes
        ↓
Sheet: suggested vaults (name + path) + [Connect] per row
        ↓
Footer: "Choose a different folder…" → NSOpenPanel
        ↓
PersonalKnowledgeManager.connectVault(at:)
  • Security-scoped bookmark
  • Persist in ~/.clicky/brain/sources.json
  • Panel: "Connected · N notes · read-only"
```

Disconnect clears Clicky’s connection + bookmarks; vault files untouched.

---

## On-demand retrieval flow

```
Push-to-talk transcript finalized
        ↓
VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript)
  NO  → existing pipeline (screenshot + teaching skills + Claude)
  YES → PersonalKnowledgeManager.search(query: transcript)
        ↓
PersonalContextAssembler.buildUserPrompt(
  originalTranscript: transcript,
  retrievedChunks: [...]
)
        ↓
Claude API with augmented user message; system prompt unchanged
        ↓
UI: lastVaultContextUsed = ["Work/Projects.md", ...]
```

### Intent detection (Phase 1 — keyword/heuristic)

Trigger when transcript matches patterns like:

- “my vault”, “my notes”, “internal knowledge”, “knowledge brain”
- “what did I write about …”, “what do my notes say about …”
- “from my obsidian”, “in clicky brain”, “remember in my notes”

Exclude false positives: “take notes” (action), generic “I know”.

Implementation: `VaultIntentDetector` enum with `shouldRetrievePersonalKnowledge(transcript:) -> Bool` + unit tests.

### Where context goes

| Layer | Default turn | Vault-intent turn |
|-------|--------------|-------------------|
| System prompt | Unchanged | Unchanged (no standing vault block) |
| User message | Raw transcript | Transcript + fenced “Relevant notes” section |
| Teaching skills | Matched as today | Matched as today |

Rationale: on-demand only; retrieved text is turn-scoped evidence, not permanent persona injection.

### Search (Phase 1 MVP)

- Ripgrep or Swift `String` scan over `.md` in connected vault roots + `~/.clicky/brain/*.md`
- Tokenize query; score by term overlap + recency (file mtime)
- Cap: ~4 chunks, ~3000 chars total
- Denylist: `.env`, `*.pem`, `.git/`, `node_modules/`

Phase 2 (later): SQLite FTS index + file watcher on connect.

---

## New Swift modules

| File | Responsibility |
|------|----------------|
| `VaultDiscoveryService.swift` | Parse `obsidian.json`; return `[DiscoveredVault(name, path)]` |
| `PersonalKnowledgeManager.swift` | Connect/disconnect, bookmarks, `sources.json`, search |
| `VaultIntentDetector.swift` | Heuristic gate for on-demand retrieval |
| `PersonalContextAssembler.swift` | Build augmented user prompt from chunks |
| `VaultConnectionSheet.swift` | SwiftUI sheet: suggestions + manual pick |
| `CompanionPanelView.swift` | Connect button, connected status, “used N notes” indicator |

Hook in `CompanionManager.sendTranscriptToClaudeWithScreenshot`:

```swift
let shouldRetrieveVault = vaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: transcript)
let userPrompt: String
if shouldRetrieveVault, personalKnowledgeManager.hasConnectedVault {
    let chunks = try await personalKnowledgeManager.search(query: transcript)
    userPrompt = PersonalContextAssembler.buildUserPrompt(
        originalTranscript: transcript,
        retrievedChunks: chunks
    )
    lastVaultNotesUsed = chunks.map(\.sourcePath)
} else {
    userPrompt = transcript
    lastVaultNotesUsed = []
}
// pass userPrompt to claudeAPI.analyzeImageStreaming(..., userPrompt: userPrompt)
```

---

## Storage layout

```
~/.clicky/brain/
  sources.json       # connected vault paths + bookmarks (base64)
  USER.md            # optional curated facts (included in search only on vault intent)
  MEMORY.md          # optional episodic memory (same)
```

`sources.json` example:

```json
{
  "vaults": [
    { "label": "Work", "path": "/Users/me/Documents/Obsidian/Work", "connectedAt": "2026-05-27T..." }
  ]
}
```

---

## Privacy & permissions

- Opt-in only; no home-directory scan beyond Obsidian registry + user-picked folder.
- Read-only default.
- Panel copy: retrieved note text goes to Claude via existing worker (same trust model as screenshots).
- Security-scoped bookmarks for persistent folder access.

---

## Build phases

### Phase A — Connect only (shippable slice 1)

- [ ] `VaultDiscoveryService` + `VaultConnectionSheet`
- [ ] `PersonalKnowledgeManager.connect/disconnect` + bookmarks
- [ ] Panel UI: connect, status, disconnect
- [ ] No retrieval yet — proves path + permissions

### Phase B — On-demand retrieval (shippable slice 2)

- [ ] `VaultIntentDetector` + tests
- [ ] `PersonalKnowledgeManager.search`
- [ ] `PersonalContextAssembler` + `CompanionManager` hook
- [ ] Panel “used N notes” indicator

### Phase C — Polish (follow-up)

- [ ] Multiple vaults
- [ ] Exclude `#private` / path rules
- [ ] SQLite FTS index
- [ ] Explicit write-back (“remember this in my vault”) — out of scope for v1

---

## Tests

| Test | Type |
|------|------|
| `VaultIntentDetector` positive/negative phrases | Unit (`leanring-buddyTests`) |
| `obsidian.json` parsing (fixture file) | Unit |
| `PersonalContextAssembler` char budget | Unit |
| Connect vault → ask vault question → user prompt contains note excerpt | E2E script (when feature flag on) |
| Unrelated screen question → user prompt has no vault block | E2E |

---

## Out of scope (this branch)

- Auto-inject vault on every turn
- Embeddings / semantic search
- Write to vault or `MEMORY.md` without explicit user command
- Obsidian wikilink resolution (Phase 2)

---

## Success criteria

1. Connect suggested Obsidian vault in one tap, or pick folder manually.
2. “What did I write about Project X?” → answer grounded in vault when X is in notes.
3. “Where is the save button?” (no vault phrasing) → no vault search, no note excerpts sent.
4. Disconnect → vault questions no longer use note content.
