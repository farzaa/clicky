//
//  GuidedSetupPromptContext.swift
//  leanring-buddy
//
//  Privacy-safe prompt context formatting for GuidedSetupSession. This file
//  serializes local metadata only; it must not add screenshots or raw user
//  entered values to the guide prompt.
//

import Foundation

extension GuidedSetupSession {
    func promptContext(
        nextPollIndex: Int,
        screenSignature: String
    ) -> String {
        let changed = screenChanged(for: screenSignature)
        var contextLines = [
            "Guided setup session metadata:",
            "sessionId=\(sessionId.uuidString)",
            "platformId=\(platformId.rawValue)",
            "pollIndex=\(nextPollIndex)",
            "currentScreenSignature=\(screenSignature)",
            "previousScreenSignature=\(lastScreenSignature ?? "none")",
            "previousSemanticSignature=\(lastSemanticSignature ?? "none")",
            "previousScreenState=\(currentScreenState.rawValue)",
            "previousScreenId=\(currentScreenId)",
            "previousStageId=\(currentStageId)",
            "previousConfidence=\(confidence.rawValue)",
            "screenChanged=\(changed)",
            "unchangedCount=\(consecutiveUnchangedCount)",
            "loadingCount=\(consecutiveLoadingCount)",
            "unknownCount=\(consecutiveUnknownCount)",
            "forceLoadingReclassification=\(shouldForceLoadingReclassification)"
        ]

        if let lastPoint {
            contextLines.append(
                "previousAcceptedTargetLabel=\(lastPoint.label?.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters) ?? "none")"
            )
            contextLines.append(
                "previousAcceptedTargetMissionAlignment=\(lastPoint.missionAlignment?.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuidePointMissionAlignmentCharacters) ?? "none")"
            )
            contextLines.append("previousAcceptedTargetScreenId=\(currentScreenId)")
            contextLines.append("previousAcceptedTargetStageId=\(currentStageId)")
        } else {
            contextLines.append("previousAcceptedTargetLabel=none")
        }

        if let pendingPointOutcome {
            contextLines.append("pendingPointOutcomeTargetElementIdHash=\(pendingPointOutcome.targetElementIdHash ?? "none")")
            contextLines.append("pendingPointOutcomeTargetFingerprint=\(pendingPointOutcome.targetFingerprint?.value ?? "none")")
            contextLines.append("pendingPointOutcomeTargetFingerprintCompatibility=\(pendingPointOutcome.targetFingerprint?.compatibilityValue ?? "none")")
            contextLines.append("pendingPointOutcomeScreenId=\(pendingPointOutcome.screenId)")
            contextLines.append("pendingPointOutcomeStageId=\(pendingPointOutcome.stageId)")
            contextLines.append("pendingPointOutcomeSemanticSignature=\(pendingPointOutcome.semanticSignature ?? "none")")
            contextLines.append("pendingPointOutcomeGroundingRevision=\(pendingPointOutcome.groundingRevision?.groundingRevision ?? "none")")
            contextLines.append("pendingPointOutcomeExpected=\(pendingPointOutcome.expectedOutcome.rawValue)")
            contextLines.append("pendingPointOutcomeVerificationKind=\(pendingPointOutcome.expectedOutcomeEvidence.verificationKind.rawValue)")
        } else if let lastFailedPointOutcome,
                  let lastGroundingOutcomeDecision {
            contextLines.append("lastFailedPointOutcomeTargetElementIdHash=\(lastFailedPointOutcome.targetElementIdHash ?? "none")")
            contextLines.append("lastFailedPointOutcomeTargetFingerprint=\(lastFailedPointOutcome.targetFingerprint?.value ?? "none")")
            contextLines.append("lastFailedPointOutcomeTargetFingerprintCompatibility=\(lastFailedPointOutcome.targetFingerprint?.compatibilityValue ?? "none")")
            contextLines.append("lastFailedPointOutcomeScreenId=\(lastFailedPointOutcome.screenId)")
            contextLines.append("lastFailedPointOutcomeStageId=\(lastFailedPointOutcome.stageId)")
            contextLines.append("lastFailedPointOutcomeSemanticSignature=\(lastFailedPointOutcome.semanticSignature ?? "none")")
            contextLines.append("lastFailedPointOutcomeGroundingRevision=\(lastFailedPointOutcome.groundingRevision?.groundingRevision ?? "none")")
            contextLines.append("lastFailedPointOutcomeExpected=\(lastFailedPointOutcome.expectedOutcome.rawValue)")
            contextLines.append("lastFailedPointOutcomeVerificationKind=\(lastFailedPointOutcome.expectedOutcomeEvidence.verificationKind.rawValue)")
            contextLines.append("lastFailedPointOutcomeStatus=\(lastGroundingOutcomeDecision.outcomeStatus.rawValue)")
            contextLines.append("lastFailedPointRetryAllowed=\(lastGroundingOutcomeDecision.retryPolicy.allowRetry)")
            contextLines.append("lastFailedPointRetryReason=\(lastGroundingOutcomeDecision.retryPolicy.reason.rawValue)")
            contextLines.append("lastFailedPointDoNotRepeatUntilSignatureChanges=\(lastGroundingOutcomeDecision.retryPolicy.doNotRepeatUntilSignatureChanges)")
            contextLines.append("lastFailedPointRequiresUserConfirmationAfterFailure=\(lastGroundingOutcomeDecision.retryPolicy.requiresUserConfirmationAfterFailure)")
        }

        if let pendingPreDotVerification {
            contextLines.append("pendingPreDotVerificationTargetFingerprint=\(pendingPreDotVerification.targetFingerprint?.value ?? "none")")
            contextLines.append("pendingPreDotVerificationCompatibility=\(pendingPreDotVerification.targetFingerprint?.compatibilityValue ?? "none")")
            contextLines.append("pendingPreDotVerificationActionRisk=\(pendingPreDotVerification.actionRisk.rawValue)")
            contextLines.append("pendingPreDotVerificationScreenType=\(pendingPreDotVerification.screenType.rawValue)")
            contextLines.append("pendingPreDotVerificationReasons=\(pendingPreDotVerification.reasons.map(\.rawValue).joined(separator: ","))")
        }

        if !negativeMemories.isEmpty {
            let activeMemories = negativeMemories
                .filter { $0.expiresAt > Date() }
                .suffix(6)
                .map { "\($0.reason.rawValue):\($0.targetFingerprint?.compatibilityValue ?? $0.targetElementIdHash ?? "unknown")" }
                .joined(separator: ",")
            if !activeMemories.isEmpty {
                contextLines.append("negativeTargetMemory=\(activeMemories)")
            }
        }

        return contextLines.joined(separator: "\n")
    }
}
