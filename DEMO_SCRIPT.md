# DEMO SCRIPT — Clicky Local Mode, 60 seconds

One continuous screen recording plus a phone shot of the wifi toggle if you want drama.
Practice the run twice; the beats are tight.

## Prep (do all of this before recording)

1. **Build & run from Xcode** (never `xcodebuild` from terminal once permissions are granted):
   open `leanring-buddy.xcodeproj`, Signing & Capabilities → select your personal team,
   Cmd+R. Xcode will ask to **Trust & Enable** the `MLXHuggingFaceMacros` plugin — say yes.
2. Complete onboarding once (grant all four permissions, email, Start).
3. **Cloud side**: the worker URL must be set for the cloud beats —
   `CompanionManager.swift` `workerBaseURL` and the AssemblyAI token URL in
   `AssemblyAIStreamingTranscriptionProvider.swift`. No worker? Record shots 3–5 only;
   the local story carries the video.
4. **While online**: open the panel, click **Local**. Watch the progress bar; wait for
   *"Local Mode — your screen stays on your Mac."* (~1.8 GB first time; instant if the
   bench already ran). First push-to-talk in Local will prompt for Speech Recognition — grant it.
5. Quit and relaunch once. Pick Local again — it loads from disk, no network. This is the
   path the demo relies on.
6. Optional but worth it: System Settings → Accessibility → Spoken Content → System Voice →
   Manage Voices → download an **Enhanced** en-US voice. The local voice picks the best
   installed automatically.
7. Flip back to **Sonnet** before recording starts.

## Shots

**1. (0–10s) Cloud baseline.**
Screen with something real (code, a chart). Hold ctrl+option: *"what am i looking at here?"*
Clicky answers in the ElevenLabs voice, points at the thing. Latency badge reads
`cloud · ~2s`. No narration needed — this is just "clicky works as always."

**2. (10–20s) Kill the wifi. On camera.**
Menu bar → wifi off. Hold ctrl+option, ask anything. Clicky answers **instantly, out loud**:
*"looks like the internet is out. flip me to local in the menu bar and i can keep helping."*
(No spinner-of-death — the app fails fast and tells you what to do.)

**3. (20–40s) Flip to Local. The money shot.**
Open the panel — picker now shows **Sonnet / Opus / Local**. Click Local. The line under it:
*"Local Mode — your screen stays on your Mac."* Close panel. Hold ctrl+option:
*"explain what a mutex is."* Spinner for under a second, then the answer — spoken, wifi still
off. Badge reads `local · 0.6s · 58 tok/s`. Let the badge sit on screen a beat.

**4. (40–55s) The privacy line.**
Ask a follow-up (*"give me an example in swift"*) to show it remembers context. Over it,
one spoken or caption line: **"wifi's off. the screenshot was never taken. nothing left
this mac — not even analytics."**

**5. (55–60s) Card.**
> **Clicky Local Mode** — built on MLX.
> 0.6s to first token · 58 tok/s · $0 · works on a plane.
> Weekend remix by Shrey Patel / Coconut Labs.

## If a beat goes sideways

- Local answer feels slow on the first try → that's the cold first generation (~1.5s first
  token); ask a second question, it drops to ~0.6s. Record the second.
- Apple voice sounds flat → it's the offline voice, own it; the README explains the tradeoff.
- Pointing fires in shot 1 but flies somewhere dumb → re-record shot 1 with a simpler screen.
