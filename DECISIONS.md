# DECISIONS — Local Mode

Each entry: the call, and why. Deviations from the original plan are marked **[deviation]**.

## Runtime & model

- **MLX via `ml-explore/mlx-swift-lm` pinned `.upToNextMajor(from: "3.31.3")`** plus
  `huggingface/swift-huggingface` (≥0.9.0) and `huggingface/swift-transformers` (≥1.3.0).
  The LLM libraries moved out of `mlx-swift-examples` in April 2026; this is the maintained
  home. Let mlx-swift-lm own the mlx-swift version (it pins `.upToNextMinor(from: 0.31.4)`).
- **Model: `mlx-community/Llama-3.2-3B-Instruct-4bit` (~1.8 GB)** via
  `LLMRegistry.llama3_2_3B_4bit`. It's a registry constant (path of least resistance), no
  thinking-token surprises (Qwen3-family templates emit them), fits the ≤2.5 GB budget, and
  the name reads well in a demo. One model, not a menu.
- **Load path: the `#huggingFaceLoadModelContainer` macro** — the README-canonical route. It
  pulls swift-syntax (slower clean builds); the alternative is ~30 lines of hand-written
  Downloader/TokenizerLoader adapters. Sugar wins: less custom plumbing in the diff, and clean
  builds are a one-time tax.
- **Model storage: `~/Library/Application Support/Clicky/models/huggingface`**, pinned with
  `HubCache(location: .fixed(directory:))`. Application Support, not Caches — macOS purges
  Caches under disk pressure and silently re-downloading 1.8 GB is a bad surprise. Never in
  the repo; `.gitignore` extended.

## Architecture

- **`BuddyChatProvider` protocol + `CloudChatProvider` + `LocalChatProvider`**, mirroring the
  existing `BuddyTranscriptionProvider` pattern (Farza's own seam, completed for chat).
  `CloudChatProvider` wraps the untouched `ClaudeAPI` — cloud behavior stays byte-for-byte.
  Routing branches in `CompanionManager` at the request site, because `ClaudeAPI`'s proxy URL
  is `private let` on a single lazy instance and the picker pipeline is plain Strings.
- **"Local" is a third `modelOptionButton` with sentinel modelID `local`**, stored in the same
  `selectedClaudeModel` UserDefaults key. Hardening: the stored value is validated on load and
  unknown values fall back to Sonnet, so a stale `local` can never reach the Anthropic API
  (which would 404).
- **The local engine lives in `LocalChatProvider`** (owns ModelContainer + download state),
  exposed to SwiftUI through `@Published` state on CompanionManager like everything else. MVVM
  graph unchanged.

## Behavior contract (Tier 1 honesty)

- **No screenshot in Local Mode** — capture is skipped entirely, not captured-and-dropped.
  `ClaudeAPI`-style empty-images requests already degrade cleanly; pointing needs a capture to
  map pixels→points, so it no-ops by construction as well as by prompt.
- **`[POINT:...]` disabled in Local Mode.** A 3B model guessing screen coordinates it has never
  seen is a clown show. The local system prompt bans the tag; the end-anchored parse regex
  would choke on malformed emissions anyway and TTS would read the tag aloud.
- **Short local system prompt** (~10 lines): keeps the clicky voice rules (lowercase, 1-2
  sentences, TTS-friendly), drops all screen/pointing/multi-monitor material — 4.3k chars of
  vision instructions wasted on a text-only 3B model otherwise.
- **[deviation] Analytics content events are gated in Local Mode** — promoted from Tier 2 to
  Tier 1 after recon found PostHog uploads the *full transcript and full response text* with no
  opt-out. "Your screen stays on your Mac" while words go to a US analytics cloud is a
  self-own. Local Mode sends a single content-free `local_mode_selected` event; transcript and
  response events don't fire.
- **[deviation] Local Mode gets its own spoken error line** instead of the global "I'm all out
  of credits, please DM Farza" fallback — that line is a lie when the actual failure is local
  inference. Kept Farza-casual.
- **[deviation] The "screen stays on your Mac" notice lives in the menu-bar panel**, under the
  picker, shown whenever Local is selected — not a once-per-session overlay toast. Recon: the
  overlay fades out aggressively (transient mode) and has no stable text surface; the panel is
  where the user makes the choice, so the disclosure sits at the decision point.

## Voice loop (offline)

- **TTS: `AVSpeechSynthesizer` client implementing the same surface as ElevenLabsTTSClient**
  (`speakText` returns at playback start, `isPlaying` true until didFinish, synchronous
  `stopPlayback`) — the transient-cursor hide loop polls `isPlaying` every 200ms and hangs
  forever if it never flips. Robotic next to ElevenLabs; it's the *offline* voice and the
  tradeoff is the point.
- **STT: Apple Speech provider, switched at runtime.** The factory resolves once at init today;
  the refactor re-resolves the provider at session start (the one seam where it's used) based
  on the selected mode. On-device recognition is verified via `supportsOnDeviceRecognition`,
  not assumed — if unsupported, the UI says so rather than silently sending audio to Apple.
  First switch to Local will trigger the speech-recognition permission prompt (usage string
  already shipped in Info.plist).

## Streaming & UX

- **[deviation] No streamed-text rendering in Tier 1.** The brief assumed the overlay renders
  tokens; recon shows the app discards them (no-op `onTextChunk`, dead
  `CompanionResponseOverlay`). Clicky's medium is voice. Local Mode matches the existing
  pipeline (spinner → spoken reply) and the latency badge (Tier 2) makes the speed difference
  visible. Reviving 217 lines of untested dead overlay code that resizes an NSPanel per token
  at 40 tok/s is a drive-by refactor with demo risk — declined.
- **First-token latency is measured in the provider layer** (wrap the first `onTextChunk`
  invocation) — no changes inside `ClaudeAPI`.
- **max_tokens parity: local generation capped at 1024** to match the cloud path
  (`ClaudeAPI.swift:144`); KV growth bounded via `GenerateParameters`.

## Out of scope (explicit)

- Local vision (Tier 3 gate: only after demo video is recordable; cut if TTFT > ~6s).
- Auto-routing local/cloud (Tier 3, manual picker must be solid first).
- Fixing the worker-URL placeholders, the unauthenticated worker, the dead
  `ElementLocationDetector`, the camera entitlement, or any known warning — not our diff.
- Streaming TTS, sentence-chunked TTS — escape hatch only if full-response TTS feels bad.

## Process

- **Terminal `xcodebuild` is used for compile verification only while this machine has zero
  TCC grants for clicky** (fresh clone, never run). Farza's rule exists because terminal
  builds invalidate *granted* permissions; there are none yet. The moment the app runs from
  Xcode and permissions are granted, terminal builds stop.
- Cloud side is blocked on a deployed worker URL (placeholders in repo). Local-first per the
  escape hatch; side-by-side demo shots happen once the worker exists.
