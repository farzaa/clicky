//
//  SpiderGuidePointSafetyPolicy.swift
//  leanring-buddy
//
//  Central policy for deciding whether a Worker-proposed guide point may reach
//  the overlay. This type intentionally owns only metadata safety rules; it
//  never stores screenshots, transcripts, prompts, or model responses.
//

import Foundation

enum SpiderGuidePointSafetyPolicy {
    enum InitialPointDecision: Equatable {
        case noPoint
        case rejected(SpiderGuidePointRejectionReason)
        case evaluable(SpiderGuidePoint)

        var point: SpiderGuidePoint? {
            guard case .evaluable(let point) = self else { return nil }
            return point
        }

        var rejectionReason: SpiderGuidePointRejectionReason? {
            guard case .rejected(let reason) = self else { return nil }
            return reason
        }
    }

    private static let restrictedScreenIds: Set<String> = [
        "login",
        "two_factor_auth_checkpoint",
        "budget_and_schedule",
        "review_publish",
        "billing_payment",
        "account_quality_policy",
        "reporting_delivery",
    ]

    private static let restrictedStageIds: Set<String> = [
        "authenticate",
        "budget_boundary",
        "billing_boundary",
        "policy_boundary",
        "manual_publish_boundary",
        "publish_boundary",
        "preflight_audit",
        "72h_review",
    ]

    private static let unsafePointLabelFragments = [
        "publish",
        "submit",
        "launch",
        "budget",
        "spend",
        "billing",
        "payment",
        "card",
        "bank",
        "tax",
        "invoice",
        "pause",
        "delete",
        "remove",
        "discard",
        "deactivate",
        "duplicate",
        "password",
        "credential",
        "2fa",
        "two-factor",
        "two factor",
        "verification code",
        "security code",
        "recovery",
        "appeal",
        "account quality",
        "business verification",
        "domain verification",
    ]

    private static let sensitivePointEvidencePattern =
        #"([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\b(?:\d[ -]?){12,19}\b|\b\d{6,8}\b|\b(?:bearer|token|password|secret|api[_ -]?key|sk-[A-Za-z0-9_-]+|pk_live_[A-Za-z0-9_-]+)\b)"#

    static func initialPointDecision(
        for guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        hasNegativeMemoryBlock: Bool = false,
        hasRepeatedFailedPointBlock: Bool = false
    ) -> InitialPointDecision {
        guard let point = guideResponse.point else { return .noPoint }
        if let rejectionReason = rejectionReason(
            for: guideResponse,
            resolvedScreenState: resolvedScreenState,
            hasNegativeMemoryBlock: hasNegativeMemoryBlock,
            hasRepeatedFailedPointBlock: hasRepeatedFailedPointBlock
        ) {
            return .rejected(rejectionReason)
        }
        return .evaluable(point)
    }

    static func rejectionReason(
        for guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        hasNegativeMemoryBlock: Bool = false,
        hasRepeatedFailedPointBlock: Bool = false
    ) -> SpiderGuidePointRejectionReason? {
        guard guideResponse.point != nil else { return nil }
        if hasNegativeMemoryBlock {
            return .negativeMemoryBlocked
        }
        if hasRepeatedFailedPointBlock {
            return .outcomeFailed
        }
        guard resolvedScreenState == .recognized else {
            return .unrecognizedScreen
        }
        guard guideResponse.screenConfidence == .high else {
            return .lowConfidence
        }
        guard !guideResponse.requiresManualConfirmation else {
            return .manualConfirmationRequired
        }

        if let screenId = guideResponse.screenId?.lowercased(),
           restrictedScreenIds.contains(screenId) {
            return .restrictedScreen
        }
        if let stageId = guideResponse.stageId?.lowercased(),
           restrictedStageIds.contains(stageId) {
            return .restrictedStage
        }
        if let label = guideResponse.point?.label?.lowercased(),
           unsafePointLabelFragments.contains(where: { label.contains($0) }) {
            return .unsafeLabel
        }
        if let label = guideResponse.point?.label,
           containsSensitivePointEvidence(label) {
            return .sensitiveEvidence
        }
        guard let missionAlignment = guideResponse.point?.missionAlignment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !missionAlignment.isEmpty else {
            return .missingMissionAlignment
        }
        let normalizedMissionAlignment = missionAlignment.lowercased()
        if unsafePointLabelFragments.contains(where: { normalizedMissionAlignment.contains($0) }) {
            return .unsafeLabel
        }
        if containsSensitivePointEvidence(missionAlignment) {
            return .sensitiveEvidence
        }

        return nil
    }

    static func rejectionReason(
        for decision: GroundingSensorFusionDecision
    ) -> SpiderGuidePointRejectionReason {
        let reasons = decision.contradictionReasons
        if reasons.contains(.actionRiskBlocked) {
            return .actionRiskBlocked
        }
        if reasons.contains(.journeyTransitionInvalid) {
            return .journeyTransitionInvalid
        }
        if reasons.contains(.targetStaleAfterScreenChange) {
            return .targetStaleAfterScreenChange
        }
        if reasons.contains(.blockedTargetOverlap) {
            return .blockedTargetOverlap
        }
        if reasons.contains(.targetAffordanceNotClickable) {
            return .affordanceNotClickable
        }
        if reasons.contains(.targetConfidenceLow) {
            return .targetConfidenceLow
        }
        if reasons.contains(.regionConfidenceLow)
            || reasons.contains(.regionImplausible)
            || reasons.contains(.calibrationStrongBlock) {
            return .regionImplausible
        }
        if reasons.contains(.targetOccluded) {
            return .targetOccluded
        }
        if reasons.contains(.visionTargetMissing) || reasons.contains(.targetRegionMissing) {
            return .elementMissing
        }
        return .sensorFusionContradicted
    }

    static func shouldHideGuidanceBubble(for reason: SpiderGuidePointRejectionReason) -> Bool {
        switch reason {
        case .sensorFusionContradicted, .actionRiskBlocked, .preDotVerificationPending,
             .preDotVerificationFailed, .preDotVerificationTimeout,
             .journeyTransitionInvalid, .negativeMemoryBlocked,
             .pointOutsideRegion, .targetConfidenceLow, .targetStaleAfterScreenChange,
             .blockedTargetOverlap, .modalContextMismatch, .affordanceNotClickable,
             .regionImplausible, .semanticSignatureChanged, .targetOccluded,
             .elementMissing, .elementConfidenceLow, .outcomeFailed, .outcomeStale:
            return true
        case .unrecognizedScreen, .lowConfidence, .manualConfirmationRequired,
             .restrictedScreen, .restrictedStage, .unsafeLabel, .missingMissionAlignment,
             .sensitiveEvidence, .sensitiveGroundingText:
            return false
        }
    }

    static func negativeMemoryReason(
        for decision: GroundingSensorFusionDecision
    ) -> GroundingNegativeMemoryReason {
        let reasons = decision.contradictionReasons
        if reasons.contains(.actionRiskBlocked) {
            return .actionRiskBlocked
        }
        if reasons.contains(.journeyTransitionInvalid) {
            return .journeyTransitionInvalid
        }
        if reasons.contains(.targetStaleAfterScreenChange) {
            return .stale
        }
        if reasons.contains(.regionConfidenceLow)
            || reasons.contains(.regionImplausible)
            || reasons.contains(.pointOutsideTargetRegion)
            || reasons.contains(.calibrationStrongBlock) {
            return .regionBad
        }
        return .sensorContradiction
    }

    private static func containsSensitivePointEvidence(_ value: String) -> Bool {
        value.range(
            of: sensitivePointEvidencePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
