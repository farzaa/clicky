# RECON — what the code actually does (verified 2026-06-12)

Call path, push-to-talk release → response, with the things the docs get wrong.

## The pipeline

```
ctrl+option release
  └─ GlobalPushToTalkShortcutMonitor (CGEvent tap) → .released
      └─ CompanionManager.handleShortcutTransition (~:528)
          └─ BuddyDictationManager.stopPushToTalk → AssemblyAI ForceEndpoint
              └─ onFinalTranscriptReady → submitDraftText
                  └─ CompanionManager.sendTranscriptToClaudeWithScreenshot (:586-726)
                      ├─ voiceState = .processing  (spinner)
                      ├─ captureAllScreensAsJPEG()   ← mandatory; failure aborts everything
                      ├─ ClaudeAPI.analyzeImageStreaming → worker /chat → SSE
                      │    └─ onTextChunk: { _ in }   ← tokens are DISCARDED
                      ├─ parsePointingCoordinates     (end-anchored [POINT:...] regex, :784)
                      ├─ ElevenLabsTTSClient.speakText (full MP3 download, then play)
                      │    └─ voiceState = .responding only after play() starts
                      └─ voiceState = .idle
```

## Where the brief / docs and reality diverge

- **No streamed text ever renders.** `onTextChunk` is a deliberate no-op
  (CompanionManager.swift:618, comment: "No streaming text display — spinner stays until TTS
  plays"). `CompanionResponseOverlay.swift` (the styled streaming bubble, 217 lines) is dead
  code — zero instantiations. Clicky's response medium is **voice**, full stop. "Stream local
  tokens into the existing overlay" therefore means: match the voice pipeline, and make latency
  visible some other way (badge).
- **Analytics uploads conversation content.** `ClickyAnalytics.trackUserMessageSent` /
  `trackAIResponseReceived` send the full transcript and full AI response to PostHog US cloud
  (ClickyAnalytics.swift:84-96), no opt-out. A Local Mode that leaves this on is privacy
  theater — gating it is part of the feature, not polish.
- **Both worker URLs are placeholders** (`CompanionManager.swift:73`,
  `AssemblyAIStreamingTranscriptionProvider.swift:22`). Fresh clone = cloud chat, TTS, and
  streaming STT are all dead until you deploy the worker. Local Mode is the only path that can
  work out of the box.
- **AssemblyAI does not fall back to Apple Speech on network failure.** The fallback chain in
  the factory is config-time only — and partially dead, since AssemblyAI's `isConfigured` is
  hardcoded `true`. Mid-session network loss surfaces an error; nothing reroutes.
- **Every pipeline error speaks "I'm all out of credits. Please DM Farza…"**
  (CompanionManager.swift:761-766, via NSSpeechSynthesizer) — wrong and confusing for a local
  inference failure.
- ElevenLabs client claims streaming playback in its header comment; it actually buffers the
  entire MP3 (`session.data(for:)`) before playing.
- `ElementLocationDetector.swift` (direct api.anthropic.com + raw key) is never instantiated —
  latent dead code, ignore it.

## The seams we exploit

- **Model picker is a plain String pipeline, zero enums.** `modelOptionButton(label:modelID:)`
  is generic (CompanionPanelView.swift:625-642); `selectedModel` is `@Published String`
  persisted under UserDefaults `selectedClaudeModel` (CompanionManager.swift:111-117). Adding
  "Local" is one call-site line. The real work is routing: `ClaudeAPI`'s URL is `private let`,
  single lazy instance — so we branch at the request site, exactly where a provider protocol
  belongs.
- **`BuddyTranscriptionProvider` is the architectural precedent** — protocol + factory,
  resolved from Info.plist key `VoiceTranscriptionProvider` (currently `assemblyai`). Caveat:
  resolved **once** in `BuddyDictationManager.init` into a `let`; runtime switching needs a
  small refactor at the single seam where the provider is touched (`startRecognitionSession`,
  BuddyDictationManager.swift:514).
- **Apple Speech provider already exists** (AppleSpeechTranscriptionProvider.swift) and
  `NSSpeechRecognitionUsageDescription` is already in Info.plist. It's only guaranteed
  on-device when `supportsOnDeviceRecognition` is true — we check, not assume.
- **TTS client contract** (what an AVSpeechSynthesizer replacement must honor, from
  ElevenLabsTTSClient.swift + call sites): `speakText` returns when playback *starts*;
  `isPlaying` is polled every 200ms by the transient-cursor hide loop
  (CompanionManager.swift:732-756) and must reliably flip false on finish; `stopPlayback()`
  must silence synchronously (called on every key press).
- **Screenshot skip degrades cleanly**: `ClaudeAPI` builds content blocks per image, so
  `images: []` is already a valid text-only request. Pointing then silently no-ops (the
  pixel→point mapping needs a capture) — which is what we want in Local Mode anyway.
- **System prompt** is `companionVoiceResponseSystemPrompt` (CompanionManager.swift:544-577),
  4.3k chars, mostly pointing protocol + multi-screen rules — a 3B model gets a short variant.
- **pbxproj is objectVersion 77** (filesystem-synchronized groups): new Swift files are picked
  up automatically; only SPM package references need project edits.
- App Sandbox **off**, Hardened Runtime **on**, `network.client` entitlement present. MLX needs
  no JIT entitlements; model downloads to Application Support work unrestricted.

## MLX Swift, June 2026 state (web-verified)

- `MLXLLM`/`MLXLMCommon` **moved out of mlx-swift-examples** into
  `github.com/ml-explore/mlx-swift-lm` — latest tag **3.31.3** (2026-04-15); 3.x is a breaking
  release (Downloader/Tokenizer protocols, `HubApi` removed). Companions:
  `huggingface/swift-huggingface` ≥0.9.0 (HubClient), `huggingface/swift-transformers` ≥1.3.0.
- Blessed load path: `#huggingFaceLoadModelContainer(configuration:progressHandler:)` macro →
  `ModelContainer`; streaming via `generate(input:parameters:)` → `AsyncStream<Generation>`
  (`.chunk` text, `.info` carries `tokensPerSecond` — free benchmark instrumentation).
- `LLMRegistry.llama3_2_3B_4bit` (mlx-community/Llama-3.2-3B-Instruct-4bit, ~1.8 GB) is a
  registry constant. Qwen2.5-3B is not (loads via explicit config, but why fight it).
- Download cache defaults to `~/.cache/huggingface/hub`; pin to Application Support via
  `HubCache(location: .fixed(directory:))`.
- Memory: `MLX.GPU.set(cacheLimit:)` is deprecated → `MLX.Memory.cacheLimit`. 3B-4bit is
  comfortable on this 16 GB M1 Pro; bound KV growth via `GenerateParameters` anyway.
- SwiftPM CLI cannot compile MLX's Metal shaders — full Xcode required (installed: 26.5).

## Dev machine

M1 Pro / 16 GB / macOS 26.6 / Xcode 26.5 + Metal toolchain. Expect ~30-60 tok/s decode for
3B-4bit (estimate — the README table gets measured numbers only).
