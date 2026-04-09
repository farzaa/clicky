# Practice Mode Plan

## Status

This document captures the implementation plan for Practice Mode before code changes begin.

This plan reflects the latest agreed product behavior:

- The panel stays essentially the same.
- The panel only adds a `Practice Mode` toggle.
- The panel may include a small explanatory line under the toggle indicating that Practice Mode uses background capture while it is enabled.
- Practice Mode suggests a challenge from the user's current screen instead of requiring a hardcoded task picker.
- Practice Mode runs passive progress detection in the background.
- The hotkey remains the main interaction surface for asking for hints, answers, progress checks, or ending the session.

This supersedes the earlier hardcoded task catalog and panel-heavy control surface idea.

## Product Goals

- Let the user turn on Practice Mode from the menu bar panel.
- Keep Clicky visible and following the cursor throughout the practice session.
- Suggest one concrete challenge based on the software visible on the screen the cursor is currently on.
- Monitor progress passively in the background without taking any autonomous action.
- Let the user press the hotkey and ask for help in natural language.
- Let the model generously interpret vague speech into a small set of practice intents.
- Only show a specific pointer target when the user is effectively asking for the answer.
- End the session automatically when the task appears complete and add a clicky message telling the user that they've completed the challenge.
- Also end the session when the user says something equivalent to "done" or "finished."

## Non-Goals

- No autonomous clicking.
- No passive background hints or unsolicited coaching.
- No region-selection UI.
- No path animation.
- No manual task picker.
- No hardcoded string matching for practice commands.

## User Experience

### Session Start

- The user enables `Practice Mode` in the panel.
- Clicky keeps the overlay visible for the full session.
- Clicky uses the existing screen-capture path and selects the current cursor screen from that result.
- Clicky asks the model to suggest one safe, concrete challenge based on what is visible.
- Clicky stores that challenge as the active practice session.
- Clicky optionally speaks the challenge aloud once and begins passive monitoring.

### During Practice

- The user works manually in the target software.
- Clicky stays present on screen and follows the cursor as usual.
- A passive monitor periodically reevaluates the current cursor screen against the active challenge.
- The passive monitor does not speak, does not point, and does not interrupt.

### Asking For Help

- While Practice Mode is active, hotkey transcripts are routed into the practice flow instead of the normal companion flow.
- The user can speak naturally.
- The model interprets the utterance into one of the supported practice intents.
- The user does not need to use exact keywords.

Supported intents:

- `SMALL_HINT`
- `HINT`
- `ANSWER`
- `CHECK_PROGRESS`
- `TERMINATE`

Examples of intent resolution:

- "hmm i'm not sure" -> `HINT`
- "just nudge me a bit" -> `SMALL_HINT`
- "tell me what to do" -> `ANSWER`
- "how am i doing" -> `CHECK_PROGRESS`
- "i'm done" -> `TERMINATE`

### Session End

- If passive evaluation concludes the challenge is complete, Practice Mode ends automatically.
- If the user says something meaning "done" or "finished," Practice Mode ends immediately.
- On exit, Clicky clears any active point target and returns to normal assistant behavior.

## Architecture Overview

Practice Mode should be added as a sibling flow inside the existing architecture, not as a separate subsystem.

- [CompanionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionManager.swift) remains the orchestrator.
- Screenshot capture continues to use the existing `CompanionScreenCaptureUtility`.
- Practice Mode should change only what is necessary and should reuse the current screenshot capture defaults instead of introducing a separate capture pipeline.
- Multimodal evaluation continues to use [ClaudeAPI.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/ClaudeAPI.swift).
- Pointer rendering continues to use the existing overlay state and coordinate-mapping path.
- The existing hotkey dictation flow is reused and branched into Practice Mode only after final transcript capture.

## Planned Files

### New Files

- [PracticeModeModels.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticeModeModels.swift)
- [PracticeSessionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticeSessionManager.swift)
- [PracticePromptBuilder.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticePromptBuilder.swift)

### Existing Files To Modify

- [CompanionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionManager.swift)
- [CompanionPanelView.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionPanelView.swift)
- [ClaudeAPI.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/ClaudeAPI.swift)

## Data Model Plan

### PracticeModeModels.swift

This file will define the lightweight model surface for Practice Mode.

Planned types:

- `PracticeVoiceIntent`
  - `smallHint`
  - `hint`
  - `answer`
  - `checkProgress`
  - `terminate`
  - `unknown`
- `PracticeSessionState`
  - `inactive`
  - `starting`
  - `active`
  - `completed`
  - `terminated`
  - `failed`
- `PracticeChallenge`
  - `title`
  - `goal`
  - `successCriteria`
  - `screenContextSummary`
- `PracticeEvaluation`
  - `resolvedIntent`
  - `sessionState`
  - `feedback`
  - `hint`
  - `pointTag`
  - `isComplete`
  - `shouldTerminate`
- `PracticeMonitorStatus`
  - `idle`
  - `running`
  - `paused`

## Prompt Plan

### PracticePromptBuilder.swift

This file will build two dedicated prompt types.

#### Challenge Suggestion Prompt

Purpose:

- Propose one concrete, safe, visually grounded challenge based on the cursor screen.

Strict output shape:

- `CHALLENGE_TITLE:`
- `CHALLENGE_GOAL:`
- `CHALLENGE_SUCCESS_CRITERIA:`
- `CHALLENGE_CONTEXT:`

Rules:

- The challenge must be visually grounded in the visible software.
- The challenge must be safe and reversible.
- The challenge must avoid destructive or costly actions.
- The challenge must be realistically evaluable from screenshots.

#### Practice Evaluation Prompt

Purpose:

- Interpret the user's utterance.
- Evaluate current progress against the active challenge.
- Return structured coaching output.
- Each request includes the active challenge plus a compact session context so the model retains continuity across separate API calls.

Strict output shape:

- `INTENT:`
- `STATE:`
- `FEEDBACK:`
- `HINT:`
- `POINT:`
- `COMPLETE:`
- `TERMINATE:`

Rules:

- Interpret user speech generously instead of requiring exact phrases.
- Prefer `HINT` over `ANSWER` when intent is ambiguous.
- Only return a point when the resolved intent is `ANSWER`.
- Return `POINT: NONE` for all other intents.
- If the task looks complete, set `COMPLETE: YES`.
- If the user is signaling they are done, set `TERMINATE: YES`.

### Compact Session Context

Each practice evaluation request should include only a small amount of prior context.

For the MVP, the request context should include:

- active challenge title
- active challenge goal
- active challenge success criteria
- last resolved practice intent
- last hint text, if any

The MVP should not:

- append a full running practice transcript
- append every prior practice evaluation
- reuse the normal companion conversation history

## Parsing Plan

### PracticeSessionManager.swift

This file will own:

- structured response parsing
- session state transitions
- normalization of malformed model output

Parser behavior:

- strip code fences if present
- parse sections case-insensitively
- tolerate missing fields
- never crash on malformed output
- normalize bad or missing values into safe defaults

Safe defaults:

- bad `INTENT` -> `unknown`
- bad `STATE` -> `active`
- missing `FEEDBACK` -> short generic fallback
- missing `HINT` -> empty string
- malformed `POINT` -> no point
- bad `COMPLETE` -> `false`
- bad `TERMINATE` -> `false`

`POINT` support:

- `POINT: NONE`
- `POINT: [POINT:none]`
- `POINT: [POINT:x,y:label:screenN]`

The implementation should reuse the current point-tag parsing shape already present in [CompanionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionManager.swift) rather than inventing a second coordinate format.

## CompanionManager Plan

### New Published State

Add published practice state to [CompanionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionManager.swift).

Planned properties:

- `isPracticeModeEnabled`
- `practiceSessionState`
- `activePracticeChallenge`
- `lastPracticeFeedback`
- `lastPracticeHint`
- `lastResolvedPracticeIntent`
- `isPracticeEvaluationInFlight`

### New Internal State

Add internal task and guard state:

- `practiceSessionManager`
- `practiceMonitorTask`
- `practiceEvaluationTask`
- `lastPassivePracticeEvaluationDate`
- `isPracticeOverlayForcedVisible`

### New Methods

Planned methods:

- `setPracticeModeEnabled(_:)`
- `startPracticeSessionFromCurrentScreen()`
- `stopPracticeSession(reason:)`
- `evaluatePracticeSession(userTranscript:isPassiveMonitorCheck:)`
- `runPassivePracticeMonitorLoop()`
- `captureCursorScreenForPractice()`
- `applyPracticePointingResult(...)`
- `clearPracticePointingResult()`

### Hotkey Branching

The current hotkey path should remain intact until transcript finalization.

After final transcript capture:

- if Practice Mode is disabled -> keep the current normal companion flow
- if Practice Mode is enabled -> route into `evaluatePracticeSession`

This keeps dictation capture unchanged and isolates Practice Mode to the post-transcription decision point.

### Passive Monitor Loop

The passive monitor loop should:

- start when Practice Mode becomes active and a challenge exists
- run on a conservative polling interval
- use the existing screen capture utility and select only the cursor screen from the returned captures
- skip work if dictation is active
- skip work if another practice evaluation is in flight
- skip work if the app is already speaking a response
- stop immediately when completion or termination is detected

Recommended first polling interval:

- every 8 seconds

Rationale:

- frequent enough to feel responsive
- slow enough to avoid excessive screenshot + model traffic

### Completion And Termination

Practice Mode should stop when either condition is met:

- passive evaluation returns `COMPLETE: YES`
- active evaluation returns `TERMINATE: YES`

Both paths should use the same shutdown routine:

- cancel passive monitoring
- cancel in-flight practice evaluation
- clear stale point target
- clear practice session state
- restore normal assistant routing

## ClaudeAPI Plan

Add two dedicated helpers to [ClaudeAPI.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/ClaudeAPI.swift).

Planned methods:

- `suggestPracticeChallenge(images:systemPrompt:userPrompt:)`
- `evaluatePracticeSession(images:systemPrompt:userPrompt:)`

Implementation notes:

- both should use non-streaming responses
- both should remain separate from the normal spoken assistant flow
- both should reuse the existing multimodal request format
- both should use the existing screenshot capture path and operate on the cursor screen only for Practice Mode

## Overlay And Pointer Plan

Practice Mode changes overlay behavior, but not the overlay architecture.

Desired behavior:

- the overlay remains visible for the entire practice session
- the buddy continues to follow the cursor throughout the session
- the buddy only points to a specific UI element during the `ANSWER` stage

Rules:

- `SMALL_HINT` -> no pointer target
- `HINT` -> no pointer target
- `CHECK_PROGRESS` -> no pointer target
- `TERMINATE` -> no pointer target
- passive monitor check -> no pointer target
- `ANSWER` -> pointer target allowed if a valid point is returned

Stale point targets must be cleared:

- when Practice Mode starts
- when Practice Mode ends
- when the resolved intent is not `ANSWER`
- when the model returns `POINT: NONE`

## Panel Plan

[CompanionPanelView.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionPanelView.swift) should remain nearly unchanged.

Planned UI changes:

- add a `Practice Mode` toggle row
- add a small secondary text line under the toggle that makes the background-capture behavior explicit
- optionally show a compact single-line session status such as the active challenge title

Explicitly not planned:

- no task picker
- no hint buttons
- no check button
- no stop button
- no large practice control surface

## MVP Constraints

The first implementation should stay intentionally narrow.

- Reuse the existing screen capture utility instead of introducing a new background capture subsystem.
- Reuse the current overlay and pointer system instead of introducing Practice Mode-specific overlay logic.
- Leave the current high-level error fallback behavior unchanged for the MVP, even if the message is imperfect.
- Change only the minimum behavior required to add Practice Mode cleanly.

## Safety And Challenge Constraints

The model should not propose arbitrary risky tasks.

Challenge-suggestion prompt constraints should bias toward:

- reversible tasks
- low-risk navigation tasks
- no billing-impacting actions
- no destructive actions
- no security-sensitive actions
- no tasks that cannot be visually verified

This is especially important for software like AWS, Stripe, GitHub settings, or admin consoles.

## Implementation Sequence

1. Add [PracticeModeModels.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticeModeModels.swift).
2. Add [PracticePromptBuilder.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticePromptBuilder.swift).
3. Add [PracticeSessionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/PracticeSessionManager.swift).
4. Extend [ClaudeAPI.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/ClaudeAPI.swift) with challenge suggestion and practice evaluation helpers.
5. Wire Practice Mode state and lifecycle into [CompanionManager.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionManager.swift).
6. Add the Practice Mode toggle to [CompanionPanelView.swift](/Users/gursimransingh/Downloads/clicky/leanring-buddy/CompanionPanelView.swift).
7. Verify passive monitoring, hotkey routing, pointer gating, and clean shutdown behavior manually.

## Verification Plan

Manual verification should cover:

- enabling Practice Mode from the panel
- challenge suggestion from the current cursor screen
- passive background progress checks
- natural-language mapping of vague speech into practice intents
- pointer only appearing during `ANSWER`
- overlay remaining visible for the full practice session
- automatic exit on visual completion
- exit on spoken "done" or "finished" intent
- full return to normal assistant behavior after Practice Mode ends

## Open Risks

- Passive monitoring can create too many model calls if the polling interval is too aggressive.
- Challenge suggestion quality may vary a lot depending on the visible UI.
- Sensitive software may tempt the model to suggest risky tasks unless the prompt is tightly constrained.
- Ambiguous screenshots may cause false positives on completion unless success criteria are written clearly.

## Default Technical Decisions

Unless changed later, the first implementation should assume:

- passive polling interval of 8 seconds
- cursor-screen-only capture for Practice Mode
- non-streaming multimodal Claude requests for both challenge suggestion and practice evaluation
- LLM-based intent interpretation instead of hardcoded phrase matching
- pointer allowed only during `ANSWER`
