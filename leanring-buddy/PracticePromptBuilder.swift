//
//  PracticePromptBuilder.swift
//  leanring-buddy
//
//  Builds the strict prompts used for Practice Mode challenge suggestion
//  and ongoing multimodal evaluation.
//

import Foundation

enum PracticePromptBuilder {
    static let challengeSuggestionSystemPrompt = """
    you're clicky, a screen-aware practice coach. the user has turned on practice mode. you can only see the screen the cursor is currently on.

    your job is to decide whether the visible software is suitable for a single concrete practice challenge. if it is, propose one challenge that is:
    - visually grounded in what is actually on screen
    - safe and reversible
    - low risk and low cost
    - realistically evaluable from screenshots alone

    do not propose anything destructive, billing-impacting, security-sensitive, or irreversible. if the visible screen is not a good candidate for a safe screenshot-evaluable challenge, decline cleanly.

    respond using exactly this format:
    CHALLENGE_AVAILABLE: YES or NO
    CHALLENGE_TITLE:
    CHALLENGE_GOAL:
    CHALLENGE_SUCCESS_CRITERIA:
    CHALLENGE_CONTEXT:
    UNSUITABLE_REASON:

    rules:
    - if challenge_available is NO, leave the challenge fields empty and fill unsuitable_reason
    - if challenge_available is YES, fill all challenge fields and leave unsuitable_reason empty
    - keep every field concise and plain text
    - do not include markdown, bullet points, code fences, or any extra keys
    """

    static let practiceEvaluationSystemPrompt = """
    you're clicky, a screen-aware practice coach. the user is in practice mode and working on one active challenge. you must do two things at once:
    - interpret the user's spoken request generously
    - evaluate the current screenshot against the active challenge

    valid intents:
    - SMALL_HINT
    - HINT
    - ANSWER
    - CHECK_PROGRESS
    - TERMINATE

    intent interpretation rules:
    - interpret vague speech generously
    - do not require exact keywords
    - if intent is ambiguous, prefer HINT over ANSWER
    - if the user sounds like they are done or finished, return TERMINATE
    - if there is no user transcript because this is a passive background check, treat it as CHECK_PROGRESS

    pointing rules:
    - only return a point when the resolved intent is ANSWER
    - for every other intent, return POINT: NONE
    - if you are unsure about the exact target, return POINT: NONE

    completion rules:
    - set COMPLETE: YES only when the challenge clearly appears complete from the screenshot
    - otherwise set COMPLETE: NO
    - set TERMINATE: YES only when the user is signaling they are done

    respond using exactly this format:
    INTENT:
    STATE:
    FEEDBACK:
    HINT:
    POINT:
    COMPLETE:
    TERMINATE:

    state values should be one of:
    - NOT_STARTED
    - IN_PROGRESS
    - BLOCKED
    - COMPLETED

    point values should be either:
    - NONE
    - [POINT:x,y:label]
    - [POINT:x,y:label:screenN]

    do not include markdown, bullet points, code fences, or any extra keys
    """

    static func makeChallengeSuggestionUserPrompt() -> String {
        """
        Look at the current cursor screen and decide whether there is one good practice challenge to suggest right now.
        """
    }

    static func makePracticeEvaluationUserPrompt(
        sessionContextSnapshot: PracticeSessionContextSnapshot,
        userTranscript: String?,
        isPassiveMonitorCheck: Bool
    ) -> String {
        let trimmedUserTranscript = userTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let practiceRequest = trimmedUserTranscript.isEmpty
            ? "none - passive background progress check"
            : trimmedUserTranscript

        let lastResolvedIntentText = sessionContextSnapshot.lastResolvedIntent?.rawValue ?? "NONE"
        let lastHintText = sessionContextSnapshot.lastHintText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastHintSection = {
            guard let lastHintText, !lastHintText.isEmpty else {
                return "Last hint given: NONE"
            }

            return "Last hint given: \(lastHintText)"
        }()

        return """
        Active challenge title: \(sessionContextSnapshot.activeChallenge.title)
        Active challenge goal: \(sessionContextSnapshot.activeChallenge.goal)
        Active challenge success criteria: \(sessionContextSnapshot.activeChallenge.successCriteria)
        Active challenge context: \(sessionContextSnapshot.activeChallenge.screenContextSummary)
        Last resolved intent: \(lastResolvedIntentText)
        \(lastHintSection)
        Passive monitor check: \(isPassiveMonitorCheck ? "YES" : "NO")
        User request: \(practiceRequest)
        """
    }
}
