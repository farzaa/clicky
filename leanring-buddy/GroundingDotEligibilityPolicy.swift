//
//  GroundingDotEligibilityPolicy.swift
//  leanring-buddy
//
//  Policy layer for deciding when a Vision-selected guide point is eligible to
//  carry the Spider dot. Sensor collection stays in GroundingSensorFusion.
//

import Foundation

enum GroundingDotEligibilityPolicy {
    static func isFastPathEligible(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        target: SpiderGuideSemanticTarget?,
        targetFingerprint: TargetFingerprint?,
        actionRisk: GroundingActionRisk,
        screenType: GroundingScreenType,
        stageType: GroundingStageType,
        regionQuality: RegionQuality,
        quickSignals: [GroundingAuxiliarySignal],
        screenChanged: Bool
    ) -> Bool {
        let screenConfidence = guideResponse.screenConfidence ?? guideResponse.confidence
        let targetIsStable = target?.targetStability.lowercased() == "stable"
        let targetPresenceAllowsFastPath = !screenChanged || (
            targetIsStable
                && targetFingerprint != nil
                && regionQuality.regionStability == .stable
        )
        guard screenConfidence == .high,
              (guideResponse.screenState == .recognized || guideResponse.screenState == nil),
              target?.targetConfidence == .high,
              targetIsStable,
              actionRisk.allowsDot,
              !actionRisk.isSensitiveBoundary,
              stageType == .safeSetup,
              regionQuality.regionConfidence == .high,
              regionQuality.regionStability == .stable,
              regionQuality.regionPlausibility == .plausible,
              regionQuality.pointInsideRegionConfidence == .high,
              targetPresenceAllowsFastPath,
              isFastPathSafeOutcome(guidePoint.expectedOutcome, screenType: screenType),
              !quickSignals.contains(where: { $0.result == .contradicted }) else {
            return false
        }

        switch screenType {
        case .cardTileSelection, .form, .wizard:
            return true
        case .table, .modalDialogPopover, .dropdown, .alertWarning,
             .reviewPublishBoundary, .loadingSkeleton, .unknown:
            return false
        }
    }

    static func fastPathDecision(
        eligibleBeforeOCR: Bool,
        quickSignals: [GroundingAuxiliarySignal],
        latency: GroundingSensorFusionLatency,
        policy: GroundingSensorFusionPolicy
    ) -> GroundingFastPathDecision {
        guard eligibleBeforeOCR else {
            return .notEligible
        }
        guard !quickSignals.contains(where: { $0.result == .contradicted }),
              latency.totalPointDecisionLatencyMs <= policy.fastPathMaxDecisionMs else {
            return .blocked
        }
        return .accepted
    }

    static func shouldSuppressDotForLatency(
        latency: GroundingSensorFusionLatency,
        fastPathDecision: GroundingFastPathDecision,
        regionQuality: RegionQuality,
        screenType: GroundingScreenType,
        stageType: GroundingStageType,
        signals: [GroundingAuxiliarySignal],
        calibrationDecision: GroundingCalibrationDecision,
        policy: GroundingSensorFusionPolicy
    ) -> Bool {
        guard latency.totalPointDecisionLatencyMs > policy.totalDecisionMaxMs,
              fastPathDecision != .accepted else {
            return false
        }

        let confirmedCount = signals.filter { $0.result == .confirmed }.count
        let regionIsCertain = regionQuality.regionConfidence == .high
            && regionQuality.regionStability == .stable
            && regionQuality.regionPlausibility == .plausible
            && regionQuality.pointInsideRegionConfidence == .high
        let contextIsSensitiveToDelay = stageType != .safeSetup
            || [.modalDialogPopover, .dropdown, .alertWarning, .reviewPublishBoundary, .loadingSkeleton].contains(screenType)
            || calibrationDecision == .requirePreDotVerification
            || confirmedCount <= 1

        return !regionIsCertain || contextIsSensitiveToDelay
    }

    static func policyContradictions(
        actionRisk: GroundingActionRisk,
        journeyDecision: GroundingJourneyDecision,
        regionQuality: RegionQuality
    ) -> [GroundingSensorFusionContradiction] {
        var contradictions: [GroundingSensorFusionContradiction] = []
        if !actionRisk.allowsDot {
            contradictions.append(.actionRiskBlocked)
        }
        if !journeyDecision.allowsDot {
            contradictions.append(.journeyTransitionInvalid)
        }
        if regionQuality.regionConfidence == .low
            || regionQuality.regionPlausibility != .plausible
            || regionQuality.pointInsideRegionConfidence == .low {
            contradictions.append(.calibrationStrongBlock)
        }
        return contradictions
    }

    static func calibrationDecision(
        actionRisk: GroundingActionRisk,
        screenType: GroundingScreenType,
        stageType: GroundingStageType,
        regionQuality: RegionQuality,
        signals: [GroundingAuxiliarySignal],
        policyContradictions: [GroundingSensorFusionContradiction]
    ) -> GroundingCalibrationDecision {
        if !actionRisk.allowsDot || stageType == .sensitiveBoundary {
            return .strongBlock
        }
        if policyContradictions.contains(.calibrationStrongBlock)
            || regionQuality.regionConfidence == .low
            || regionQuality.regionPlausibility != .plausible
            || regionQuality.pointInsideRegionConfidence == .low {
            return .strongBlock
        }

        let signalContradictions = signals.flatMap(\.contradictionReasons)
        let onlyOCRContradicts = !signalContradictions.isEmpty
            && Set(signalContradictions.map(\.rawValue)) == Set([GroundingSensorFusionContradiction.ocrTextMismatch.rawValue])
        let cursorConfirmed = signals.contains { $0.source == .cursorMetadata && $0.result == .confirmed }
        if onlyOCRContradicts,
           cursorConfirmed,
           regionQuality.regionConfidence == .high,
           screenType != .reviewPublishBoundary {
            return .downgradedOCROnlyContradiction
        }

        if regionQuality.regionConfidence == .medium
            || [.new, .shifted, .unknown].contains(regionQuality.regionStability)
            || [.modalDialogPopover, .dropdown].contains(screenType) {
            return .requirePreDotVerification
        }

        return .allow
    }

    static func preDotVerificationReasons(
        guideResponse: SpiderGuideResponse,
        target: SpiderGuideSemanticTarget?,
        actionRisk: GroundingActionRisk,
        screenType: GroundingScreenType,
        stageType: GroundingStageType,
        regionQuality: RegionQuality,
        signals: [GroundingAuxiliarySignal],
        latency: GroundingSensorFusionLatency,
        fastPathDecision: GroundingFastPathDecision,
        calibrationDecision: GroundingCalibrationDecision,
        screenChanged: Bool,
        policy: GroundingSensorFusionPolicy
    ) -> [GroundingPreDotVerificationReason] {
        guard actionRisk.allowsDot,
              stageType != .sensitiveBoundary,
              calibrationDecision != .strongBlock else {
            return []
        }

        var reasons: [GroundingPreDotVerificationReason] = []
        let targetStability = target?.targetStability.lowercased()
        if targetStability == "new" || targetStability == "unknown" {
            reasons.append(.targetNewOrUnknown)
        }
        if screenChanged && fastPathDecision != .accepted {
            reasons.append(.screenChanged)
        }
        if regionQuality.regionConfidence == .medium {
            reasons.append(.regionMedium)
        }
        if [.new, .shifted, .unknown].contains(regionQuality.regionStability) {
            reasons.append(.regionUnstable)
        }
        if [.modalDialogPopover, .dropdown].contains(screenType)
            || guideResponse.semanticGrounding?.blockedTargets.contains(where: {
                ["modal", "dialog", "popover"].contains($0.container.lowercased())
            }) == true {
            reasons.append(.overlayVisible)
        }
        if stageType == .sensitiveBoundary {
            reasons.append(.sensitiveStage)
        }

        let confirmedCount = signals.filter { $0.result == .confirmed }.count
        let weakCount = signals.filter { $0.result == .weaklyConfirmed }.count
        if confirmedCount == 0 || (confirmedCount + weakCount) <= 1 {
            reasons.append(.weakFusion)
        }
        if latency.totalPointDecisionLatencyMs > policy.totalDecisionMaxMs {
            reasons.append(.latencyExceeded)
        }
        var seen = Set<String>()
        return reasons.filter { seen.insert($0.rawValue).inserted }
    }

    private static func isFastPathSafeOutcome(
        _ expectedOutcome: SpiderGuideExpectedOutcome,
        screenType: GroundingScreenType
    ) -> Bool {
        switch GroundingExpectedOutcomeKind(expectedOutcome: expectedOutcome) {
        case .tileSelected, .fieldFocused, .fieldFilled, .buttonEnabled,
             .buttonDisabled, .stateChanged:
            return true
        case .screenAdvanced, .wizardAdvanced:
            return screenType == .wizard
        case .modalOpened, .modalClosed, .dropdownOpened, .warningAppeared,
             .warningCleared, .unknown:
            return false
        }
    }
}
