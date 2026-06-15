# Clicky Local Mode

Flip the model picker to **Local** and clicky answers on your Mac. First token in 0.6
seconds. Costs nothing per question. Works on a plane. And your screen never leaves the
machine — in Local Mode the screenshot is not captured at all.

This is a weekend remix of the open-source clicky by Shrey Patel ([Coconut Labs](https://coconutlabs.org)).
I build inference systems — local inference on Apple Silicon and fairness scheduling for
shared inference servers — so this is the feature I couldn't not build.

## Why this feature

**Privacy.** An assistant that sees everything you see has to earn trust structurally, not
with a policy page. Local Mode is the structural answer: no screenshot, no upload, nothing
to leak. While mapping the code I also found the analytics layer ships full transcripts and
full AI responses to PostHog — so in Local Mode those events don't fire either. A privacy
mode that phones home is a self-own.

**Cost.** The kid in Lagos doesn't have an API budget. A 3B model on the GPU he already
owns makes the buddy free at the margin.

**Latency.** No network round trip, no proxy hop. 0.6s to first token is a felt difference
in a cursor companion.

**The platform play.** Apple Intelligence is coming for this category. A clicky that's
natively excellent on Apple Silicon — Metal, MLX, on-device speech both directions — is
the counter-move.

## What got built

- **`BuddyChatProvider`** — a protocol seam for chat backends, mirroring the
  `BuddyTranscriptionProvider` pattern already in the codebase. The cloud path wraps the
  existing `ClaudeAPI` untouched; Sonnet/Opus behave exactly as before.
- **`LocalChatProvider`** — Llama-3.2-3B-Instruct (4-bit, ~1.8 GB) via
  [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm). Downloads once with a progress
  bar in the panel, then loads from disk in 3 seconds on every later launch — fully offline.
- **Offline voice loop** — Local Mode switches STT to Apple Speech (on-device) and TTS to
  `AVSpeechSynthesizer`. Push-to-talk → transcription → answer → spoken reply, wifi off.
- **A strict behavioral contract** — no screenshot captured (not captured-and-dropped),
  cursor pointing disabled (a 3B model guessing screen coordinates is a clown show), a
  trimmed local system prompt, and no conversation content in analytics.
- **Latency badge** — provider + first-token time next to the cursor while the answer
  plays (`local · 0.6s · 58 tok/s`). The benchmark as UI.
- **Offline fast-fail** — cloud requests used to hang up to 120s with no network
  (`waitsForConnectivity`). Now clicky says it's offline and points you at Local, instantly.

```
push-to-talk ──► speech-to-text ──► BuddyChatProvider ──► text-to-speech
                       │                    │                    │
        cloud:    AssemblyAI         ClaudeAPI (worker)     ElevenLabs
        local:   Apple Speech      MLX · Llama-3.2-3B      AVSpeech
                                   no screenshot · no pointing
                                   no content analytics
```

## Measured numbers

M1 Pro, 16 GB, macOS 26.6. Measured with `bench/LocalModeBench` — same model, same cache
directory, same generation parameters as the app. Run it yourself; never trust a README.

| metric | local mode |
|---|---|
| first token | **0.6–0.7 s** |
| decode speed | **54–60 tok/s** |
| model load from disk | 3.0 s |
| one-time download | 1.8 GB (83 s for me) |
| cost per question | $0 |
| network needed | none |

Cloud numbers aren't in this table because this clone ships placeholder worker URLs and I
won't print numbers I didn't measure. The in-app latency badge shows both live —
typical Claude time-to-first-token through the worker is on the order of 1.5–2.5s, and the
demo video shows the side-by-side.

```bash
cd bench/LocalModeBench
xcodebuild -scheme LocalModeBench -destination 'platform=macOS' \
  -derivedDataPath /tmp/bench-dd -skipMacroValidation build
/tmp/bench-dd/Build/Products/Debug/LocalModeBench
```

## The honest tradeoffs

- The Apple voice is robotic next to ElevenLabs. It's the *offline* voice — the tradeoff is
  the point, and you can soften it by downloading an Enhanced voice in System Settings.
- A 3B model is great at quick explanations and conversation, and it is not Opus. That's
  why it's a picker option, not a replacement.
- No local vision yet. Local Mode says so plainly when you ask about the screen, instead of
  hallucinating coordinates. See below.

## What I'd build next

1. **An auto-routing brain.** Short question, no screen needed → local. Screen question or
   deep reasoning → cloud. The picker disappears; clicky just feels instant and cheap.
2. **Fully-local screen understanding.** A 2B-class VLM via MLX answering single-screenshot
   questions on-device — true private screen help, the half of clicky Local Mode can't do yet.
3. **Fleet-scale inference fairness.** When thousands of clicky buddies share hosted
   inference, one chatty user starves the rest — scheduling and fairness on the inference
   server is the moat nobody sees coming. This is literally my research lane
   ([KVWarden](https://kvwarden.org): tenant-fair scheduling for shared LLM servers).

## Running it

Xcode 16.3+ (Swift macros — Trust & Enable the `MLXHuggingFaceMacros` plugin when asked).
Open `leanring-buddy.xcodeproj`, set your signing team, Cmd+R. Pick **Local** in the panel,
let the model download once, then turn your wifi off and talk to it.

MIT, like the original. Thanks to Farza for open-sourcing a codebase fun enough to spend a
weekend inside.
