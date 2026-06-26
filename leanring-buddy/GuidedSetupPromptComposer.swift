//
//  GuidedSetupPromptComposer.swift
//  leanring-buddy
//
//  Typed prompt and Worker context composition for guided setup.
//

import Foundation

enum GuidedSetupPromptComposer {
    static let currentScreenTranscript = "Guide the current paid ads screen with the active platform pack. Point at the next exact click or field. Use short dialogue: display max 8 words, voice max 2 short sentences. Stop before Publish. Spider never spends."

    static func pollTranscript(pollIndex: Int) -> String {
        """
        Guided setup visual poll \(pollIndex). Re-read the current screen from the screenshot, not from prior assumptions. Classify the screen state as loading, recognized, unknown, or blocked. Return screenId, stageId, screenConfidence, short non-sensitive screenEvidence, shouldContinuePolling, and optional pollAfterMs. Recognized paid ads screens include login, 2FA/auth checkpoint, account picker, business selection, dashboard, campaign table, create campaign, objective screen, campaign settings, budget, audience, creative, tracking, review/publish, billing/payment, account quality/policy, and reporting. If loading is gone, do not say Loading. If you do not recognize the current screen with confidence, say "Não reconheci ainda" or the user's selected app language equivalent. Keep display 3-8 words and voice 1-2 short sentences. Point only when the screen is recognized with high confidence and the next visible element is safe. Never point to billing, publish, budget edit, pause, delete, payment, 2FA, credentials, recovery, tax, bank, card, or irreversible account actions. Spider never clicks, never publishes, never changes budget, and never touches billing.
        """
    }

    static func transcript(
        _ transcript: String,
        addingSessionContextFrom guidedSetupSession: GuidedSetupSession?,
        screenSignature: String,
        pollIndex: Int
    ) -> String {
        guard let guidedSetupSession else {
            return transcript
        }

        return [
            transcript,
            guidedSetupSession.promptContext(
                nextPollIndex: pollIndex,
                screenSignature: screenSignature
            ),
            "If screenChanged=true, do not inherit the prior loading state automatically. If forceLoadingReclassification=true, classify from the current screenshot again and do not return loading unless a real spinner, skeleton, or blank transition is visible now."
        ].joined(separator: "\n\n")
    }

    static func sessionContext(
        from guidedSetupSession: GuidedSetupSession?,
        screenSignature: String
    ) -> SpiderGuidedSessionContext? {
        guard let guidedSetupSession else { return nil }
        let previousAcceptedTarget = guidedSetupSession.lastPoint.map {
            SpiderGuidedSessionContext.PreviousAcceptedTarget(
                label: $0.label?.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters
                ),
                missionAlignment: $0.missionAlignment?.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxGuidePointMissionAlignmentCharacters
                ),
                screenId: guidedSetupSession.currentScreenId.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
                ),
                stageId: guidedSetupSession.currentStageId.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
                )
            )
        }

        return SpiderGuidedSessionContext(
            currentScreenSignature: screenSignature.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            previousScreenSignature: guidedSetupSession.lastScreenSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            previousSemanticSignature: guidedSetupSession.lastSemanticSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            screenChanged: guidedSetupSession.screenChanged(for: screenSignature),
            pendingPointOutcome: guidedSetupSession.pendingPointOutcome.map {
                let retryPolicy = guidedSetupSession.lastGroundingOutcomeDecision?.retryPolicy
                return SpiderGuidedSessionContext.PendingPointOutcome(
                    targetElementIdHash: $0.targetElementIdHash,
                    targetFingerprint: $0.targetFingerprint?.value,
                    targetFingerprintCompatibility: $0.targetFingerprint?.compatibilityValue,
                    screenId: $0.screenId,
                    stageId: $0.stageId,
                    semanticSignature: $0.semanticSignature,
                    groundingRevision: $0.groundingRevision?.groundingRevision,
                    expectedOutcome: $0.expectedOutcome,
                    retryAllowed: retryPolicy?.allowRetry,
                    retryReason: retryPolicy?.reason.rawValue,
                    requiresUserConfirmationAfterFailure: retryPolicy?.requiresUserConfirmationAfterFailure,
                    doNotRepeatUntilSignatureChanges: retryPolicy?.doNotRepeatUntilSignatureChanges
                )
            },
            previousAcceptedTarget: previousAcceptedTarget
        )
    }
}
