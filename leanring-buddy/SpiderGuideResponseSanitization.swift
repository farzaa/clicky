//
//  SpiderGuideResponseSanitization.swift
//  leanring-buddy
//
//  Local sanitization for Worker guide responses before UI use or local
//  persistence. This file intentionally contains no HTTP transport.
//

import Foundation

extension SpiderArtifact {
    func sanitizedForLocalStorage() -> SpiderArtifact? {
        let sanitizedTitle = title.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxArtifactTitleCharacters)
        let sanitizedMarkdown = markdown.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxArtifactMarkdownCharacters)

        guard !sanitizedTitle.isEmpty, !sanitizedMarkdown.isEmpty else {
            return nil
        }

        return SpiderArtifact(
            kind: kind,
            title: sanitizedTitle,
            markdown: sanitizedMarkdown
        )
    }
}

extension SpiderGuideResponse {
    func sanitizedForUse() throws -> SpiderGuideResponse {
        let sanitizedSpokenText = spokenText.spiderSanitizedShortDialogue(
            maxCharacters: 220,
            maxWords: 22,
            maxSentences: 2
        )
        let sanitizedDisplayText = displayText.spiderSanitizedShortDialogue(
            maxCharacters: 64,
            maxWords: 8,
            maxSentences: 1
        )
        let sanitizedNextStep = nextStep.spiderSanitizedShortDialogue(
            maxCharacters: 140,
            maxWords: 14,
            maxSentences: 1
        )
        let sanitizedScreenId = screenId?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedStageId = stageId?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedScreenEvidence = screenEvidence?
            .prefix(SpiderContentLimits.maxGuideScreenEvidenceItems)
            .map {
                $0.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
                )
            }
            .filter { !$0.isEmpty }
        let sanitizedPollAfterMs: Int? = {
            guard let pollAfterMs else { return nil }
            guard pollAfterMs >= 1_000,
                  pollAfterMs <= SpiderContentLimits.maxGuidePollAfterMilliseconds else {
                return nil
            }
            return pollAfterMs
        }()
        let sanitizedSpiderJudgment = spiderJudgment.spiderSanitizedMultiline(
            maxCharacters: SpiderContentLimits.maxGuideDisplayTextCharacters
        )
        let sanitizedOfficialRule = officialRule?.spiderSanitizedMultiline(
            maxCharacters: SpiderContentLimits.maxGuideDisplayTextCharacters
        )
        let sanitizedReviewTrigger = reviewTrigger?.spiderSanitizedMultiline(
            maxCharacters: SpiderContentLimits.maxGuideNextStepCharacters
        )
        let sanitizedDecisionMemoryUpdate = decisionMemoryUpdate?.spiderSanitizedMultiline(
            maxCharacters: SpiderContentLimits.maxProjectListItemCharacters
        )

        guard !sanitizedDisplayText.isEmpty,
              !sanitizedNextStep.isEmpty,
              !sanitizedSpiderJudgment.isEmpty else {
            throw SpiderGuideResponseValidationError.missingRequiredGuidanceText
        }

        return SpiderGuideResponse(
            spokenText: sanitizedSpokenText,
            displayText: sanitizedDisplayText,
            nextStep: sanitizedNextStep,
            semanticGrounding: semanticGrounding?.sanitizedForUse(),
            screenState: screenState,
            screenId: sanitizedScreenId,
            stageId: sanitizedStageId,
            screenConfidence: screenConfidence,
            screenEvidence: sanitizedScreenEvidence,
            shouldContinuePolling: shouldContinuePolling,
            pollAfterMs: sanitizedPollAfterMs,
            contextKind: contextKind,
            officialRule: sanitizedOfficialRule,
            spiderJudgment: sanitizedSpiderJudgment,
            decision: decision,
            riskLevel: riskLevel,
            confidence: confidence,
            sourceType: sourceType,
            requiresManualConfirmation: requiresManualConfirmation,
            reviewTrigger: sanitizedReviewTrigger,
            decisionMemoryUpdate: sanitizedDecisionMemoryUpdate,
            point: point?.sanitizedForUse(),
            adMissionUpdate: adMissionUpdate?.sanitizedForLocalStorage(),
            artifact: artifact?.sanitizedForLocalStorage()
        )
    }
}

extension SpiderGuidePoint {
    func sanitizedForUse() -> SpiderGuidePoint? {
        guard x.isFinite, y.isFinite else {
            return nil
        }
        if let screenNumber,
           (screenNumber < 1 || screenNumber > SpiderContentLimits.maxGuidePointScreenNumber) {
            return nil
        }

        return SpiderGuidePoint(
            x: x,
            y: y,
            label: label?.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters),
            screenNumber: screenNumber,
            missionAlignment: missionAlignment?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuidePointMissionAlignmentCharacters
            ),
            targetElementId: targetElementId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            expectedOutcome: expectedOutcome
        )
    }
}

extension SpiderGuideSemanticGrounding {
    func sanitizedForUse() -> SpiderGuideSemanticGrounding {
        SpiderGuideSemanticGrounding(
            groundingRevision: groundingRevision?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            semanticSignature: semanticSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            elements: elements
                .prefix(SpiderContentLimits.maxGuideGroundingTargets * 3)
                .compactMap { $0.sanitizedForUse() },
            visibleConcepts: visibleConcepts.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxGuideGroundingVisibleConcepts,
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            ),
            interactiveTargets: interactiveTargets
                .prefix(SpiderContentLimits.maxGuideGroundingTargets)
                .compactMap { $0.sanitizedForUse() },
            blockedTargets: blockedTargets
                .prefix(SpiderContentLimits.maxGuideGroundingTargets)
                .compactMap { $0.sanitizedForUse() },
            uncertainty: uncertainty.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxGuideGroundingUncertainties,
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            )
        )
    }
}

extension SpiderGuideSceneGraphElement {
    func sanitizedForUse() -> SpiderGuideSceneGraphElement? {
        let sanitizedId = id.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedRole = role.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedZIndexHint = zIndexHint.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        guard !sanitizedId.isEmpty,
              !sanitizedRole.isEmpty,
              !sanitizedZIndexHint.isEmpty else {
            return nil
        }

        return SpiderGuideSceneGraphElement(
            id: sanitizedId,
            label: label.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters),
            role: sanitizedRole,
            containerId: containerId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            parentId: parentId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            zIndexHint: sanitizedZIndexHint,
            occluded: occluded,
            region: region?.sanitizedForUse(),
            confidence: confidence,
            evidence: evidence.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxGuideScreenEvidenceItems,
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            )
        )
    }
}

extension SpiderGuideSemanticTarget {
    func sanitizedForUse() -> SpiderGuideSemanticTarget? {
        let sanitizedRole = role.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedContainer = container.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedState = state.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedRisk = risk.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedAffordance = affordance.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        let sanitizedTargetStability = targetStability.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        )
        guard !sanitizedRole.isEmpty,
              !sanitizedContainer.isEmpty,
              !sanitizedState.isEmpty,
              !sanitizedRisk.isEmpty,
              !sanitizedAffordance.isEmpty,
              !sanitizedTargetStability.isEmpty else {
            return nil
        }

        return SpiderGuideSemanticTarget(
            elementId: elementId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            label: label.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters),
            role: sanitizedRole,
            container: sanitizedContainer,
            parentLabel: parentLabel?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters
            ),
            nearestText: nearestText.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxGuideScreenEvidenceItems,
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            ),
            semanticIntent: semanticIntent.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            ),
            state: sanitizedState,
            risk: sanitizedRisk,
            targetConfidence: targetConfidence,
            evidence: evidence.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxGuideScreenEvidenceItems,
                maxCharacters: SpiderContentLimits.maxGuideScreenEvidenceCharacters
            ),
            affordance: sanitizedAffordance,
            targetStability: sanitizedTargetStability,
            region: region?.sanitizedForUse()
        )
    }
}

extension SpiderGuideRegion {
    func sanitizedForUse() -> SpiderGuideRegion? {
        guard x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              x >= 0,
              y >= 0,
              width > 0,
              height > 0 else {
            return nil
        }

        return self
    }
}
