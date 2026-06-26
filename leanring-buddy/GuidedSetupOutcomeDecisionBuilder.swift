//
//  GuidedSetupOutcomeDecisionBuilder.swift
//  leanring-buddy
//
//  Builds outcome decisions for previously accepted guided-setup points. This
//  file is pure decision work; GuidedSetupSession remains the mutation boundary.
//

import Foundation

enum GuidedSetupOutcomeDecisionBuilder {
    static func decision(
        pendingPointOutcome: PendingGuidePointOutcome,
        response: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        screenChanged: Bool
    ) -> GroundingOutcomeDecision {
        let nextIdentity = GuidedSetupScreenIdentityResolver.sanitizedOutcomeIdentity(
            from: response,
            resolvedScreenState: resolvedScreenState
        )
        let nextScreenId = nextIdentity.screenId
        let nextStageId = nextIdentity.stageId
        let nextSemanticSignature = response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
        )
        let expectedOutcomeEvidence = pendingPointOutcome.expectedOutcomeEvidence
        let semanticChanged = nextSemanticSignature != nil
            && expectedOutcomeEvidence.startingSemanticSignature != nil
            && nextSemanticSignature != expectedOutcomeEvidence.startingSemanticSignature
        let stageChanged = nextStageId != expectedOutcomeEvidence.startingStageId
        let screenAdvanced = nextScreenId != expectedOutcomeEvidence.startingScreenId || stageChanged
        let semanticOutcomeEvidence = GuidedSetupSemanticOutcomeEvaluator.evaluate(
            in: response.semanticGrounding,
            stageId: nextStageId,
            expectedOutcome: expectedOutcomeEvidence.expectedOutcome,
            targetElementIdHash: expectedOutcomeEvidence.targetElementIdHash,
            targetFingerprint: expectedOutcomeEvidence.targetFingerprint
        )
        let nextTargetElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: response.point?.targetElementId)
        let pointTargetReappeared = expectedOutcomeEvidence.targetElementIdHash != nil
            && expectedOutcomeEvidence.targetElementIdHash == nextTargetElementIdHash
        let targetReappeared = pointTargetReappeared || semanticOutcomeEvidence.targetReappeared
        let targetStillSame = targetReappeared
            && !stageChanged
            && !semanticChanged
        let blockedOrUnknownAfterAction = resolvedScreenState == .blocked || resolvedScreenState == .unknown

        let status = GuidedSetupOutcomeStatusResolver.resolve(
            expectedOutcomeEvidence: expectedOutcomeEvidence,
            resolvedScreenState: resolvedScreenState,
            screenChanged: screenChanged,
            screenAdvanced: screenAdvanced,
            semanticSignatureChanged: semanticChanged,
            semanticOutcomeEvidence: semanticOutcomeEvidence
        )
        let actualOutcomeEvidence = ActualOutcomeEvidence(
            nextScreenState: resolvedScreenState,
            nextScreenConfidence: response.screenConfidence ?? response.confidence,
            nextScreenId: nextScreenId,
            nextStageId: nextStageId,
            nextSemanticSignature: nextSemanticSignature,
            screenChanged: screenChanged,
            stageChanged: stageChanged,
            semanticSignatureChanged: semanticChanged,
            targetReappeared: targetReappeared,
            targetStillSame: targetStillSame,
            modalVisible: semanticOutcomeEvidence.modalVisible,
            selectedTargetVisible: semanticOutcomeEvidence.selectedTargetVisible,
            focusedFieldVisible: semanticOutcomeEvidence.focusedFieldVisible,
            filledFieldVisible: semanticOutcomeEvidence.filledFieldVisible,
            enabledButtonVisible: semanticOutcomeEvidence.enabledButtonVisible,
            disabledButtonVisible: semanticOutcomeEvidence.disabledButtonVisible,
            dropdownVisible: semanticOutcomeEvidence.dropdownVisible,
            modalClosed: semanticOutcomeEvidence.modalClosed,
            wizardAdvanced: screenAdvanced || semanticOutcomeEvidence.wizardAdvanced,
            warningVisible: semanticOutcomeEvidence.warningVisible,
            warningCleared: semanticOutcomeEvidence.warningCleared,
            blockedOrUnknownAfterAction: blockedOrUnknownAfterAction,
            outcomeStatus: status
        )
        let retryPolicy = GuidedSetupRetryPolicy.resolve(
            for: status,
            actualOutcomeEvidence: actualOutcomeEvidence,
            attemptCount: pendingPointOutcome.attemptCount
        )

        return GroundingOutcomeDecision(
            expectedOutcomeEvidence: expectedOutcomeEvidence,
            actualOutcomeEvidence: actualOutcomeEvidence,
            retryPolicy: retryPolicy
        )
    }
}
