# TAKEOVER — offline autonomous mode (spike)

Status: **spike, in progress.** This is the "Jarvis" feature — clicky takes over the cursor
and keyboard and does a task for you. The hard constraint, from the user: **offline only.**

## The contradiction, resolved

"Autonomous + offline" can't run on the Local Mode text model. A computer-use loop has to
*see* the screen to drive it, and Llama-3.2-3B is text-only — which is exactly why Local
Mode disables screenshots and pointing. So takeover swaps in a local **vision** model:

- `MLXVLM` ships in the same `mlx-swift-lm` package already wired into the app.
- `VLMRegistry.qwen2_5VL3BInstruct4Bit` and `.qwen3VL4BInstruct4Bit` are registry constants
  — small enough for a 16 GB M1 Pro, 4-bit.
- Screenshot → `UserInput.Image.ciImage(CIImage)` → same `ModelContainer.prepare/generate`
  path as the text model.

**The honest reality:** small local VLMs are unreliable at precise UI coordinate grounding.
A 3B model will misclick. Frontier cloud models nail "click that exact button"; a 3B on
your Mac won't, consistently. So the rails below aren't bureaucracy — they're what makes a
misgrounding click harmless instead of destructive.

## Loop

```
"hey clicky, take over — <task>"
  └─ precheck: in Local Mode? network actually off? VLM loaded?  (else refuse, say why)
  └─ loop, capped at N steps and M seconds:
       screenshot ─► downscale ─► local VLM ─► one JSON action
          ▲             (cursor screen only)        │
          │                                         ▼
          │            guardrail check ─► execute (or dry-run) ─► narrate via TTS
          └──────────────── re-screenshot ◄─────────────────────┘
       exit on: action=="done" · step/time cap · stuck-loop detect · KILL SWITCH
```

Action schema (minimal — what a 3B can reliably emit):
`{"action":"click|type|scroll|key|done|give_up", ...args, "why":"..."}`

## Guardrails (non-negotiable, priority order)

1. **Offline-only enforcement.** Refuses to start unless the picker is on Local *and*
   `NWPathMonitor` reports no network. The whole point is privacy; takeover that could phone
   home is off the table.
2. **Kill switch.** A global key (ESC held, or a dedicated combo) aborts mid-loop instantly,
   via a listen-only CGEvent tap that the synthesizer can't trigger itself.
3. **Dry-run by default.** Clicky moves the cursor to where it *would* act and narrates the
   step — but does not click or type. Safe to demo on anything. Real actions require an
   explicit **arm** toggle.
4. **Confirm gate before irreversible actions** (even when armed): typing into a field,
   pressing return/enter, any key combo, or clicking a control whose label matches
   send/delete/buy/confirm/submit/pay. Clicky asks first.
5. **Hard caps.** Step count and wall-clock ceiling; stuck-loop detection (same
   action/screenshot repeating) bails with a spoken "i'm stuck on this one."

## Input monitoring (the "watch what I do" piece)

Listen-only observation of your clicks + keystrokes so clicky has context for takeover
("you were just in VS Code on line 40"). Strict shape:

- **Opt-in toggle**, off by default. **Offline-only.** On-device **bounded ring buffer**
  (last ~N events), **never transmitted, never persisted to disk.**
- Uses a passive `CGEventTapOptions.listenOnly` tap — likely needs the separate macOS
  **Input Monitoring** permission (`kTCCServiceListenEvent`), distinct from Accessibility.
  (Recon confirming.) Usage string added to Info.plist.
- This is you watching your own machine for your own assistant — kept local and gated so it
  stays that and only that.

## What this is and isn't

- It's a constrained, rail-guarded, offline computer-use agent on a small local VLM. A real
  "oh damn" demo beat on a *safe, bounded task* ("open hacker news, scroll to the top
  comment").
- It is not a reliable hands-off operator. ~3–8 s per step on M1 Pro, and it will misground.
  Dry-run is the default for a reason.

## Build order

1. `ComputerUseActionExecutor` — CGEvent synthesis (move/click/type/scroll/key) with a
   dry-run flag and the kill-switch tap. Lowest-level, testable in isolation.
2. `LocalVisionAgent` — VLM load (reuses LocalChatProvider's download/cache machinery),
   the JSON-action prompt, the loop, stuck detection, caps.
3. `TakeoverController` on CompanionManager — offline/local enforcement, arm/dry-run state,
   confirm gates, TTS narration, wires to the existing screenshot utility + voice.
4. Input-monitor observer + its permission + Info.plist string + opt-in toggle in the panel.
5. Trigger phrase ("take over") detected in the transcript, routed to TakeoverController.
