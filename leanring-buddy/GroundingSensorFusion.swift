//
//  GroundingSensorFusion.swift
//  leanring-buddy
//
//  Local, privacy-safe confirmation layer for Vision-selected guide points.
//  Auxiliary sensors can confirm or contradict Vision; they never create a
//  point on their own.
//

import Foundation

@MainActor
enum GroundingSensorFusion {
    static func evaluate(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture],
        browserMetadata: GroundingBrowserMetadata? = nil,
        screenChanged: Bool = false,
        policy: GroundingSensorFusionPolicy = .default
    ) async -> GroundingSensorFusionDecision {
        let evaluationStartedAt = Date()
        let observation = GroundingSensorFusionSignalCollector.collect(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            screenCaptures: screenCaptures,
            browserMetadata: browserMetadata,
            screenChanged: screenChanged,
            policy: policy,
            evaluationStartedAt: evaluationStartedAt
        )
        let contextClassification = observation.contextClassification
        let actionRisk = contextClassification.actionRisk
        let screenType = contextClassification.screenType
        let stageType = contextClassification.stageType
        let journeyDecision = contextClassification.journeyDecision
        let regionQuality = observation.regionQuality
        let signals = observation.signals
        let latency = observation.latency
        let fastPathDecision = GroundingDotEligibilityPolicy.fastPathDecision(
            eligibleBeforeOCR: observation.fastPathEligibleBeforeOCR,
            quickSignals: observation.quickSignals,
            latency: latency,
            policy: policy
        )
        var policyContradictions = GroundingDotEligibilityPolicy.policyContradictions(
            actionRisk: actionRisk,
            journeyDecision: journeyDecision,
            regionQuality: regionQuality
        )
        let baseCalibrationDecision = GroundingDotEligibilityPolicy.calibrationDecision(
            actionRisk: actionRisk,
            screenType: screenType,
            stageType: stageType,
            regionQuality: regionQuality,
            signals: signals,
            policyContradictions: policyContradictions
        )
        let dotSuppressedByLatency = GroundingDotEligibilityPolicy.shouldSuppressDotForLatency(
            latency: latency,
            fastPathDecision: fastPathDecision,
            regionQuality: regionQuality,
            screenType: screenType,
            stageType: stageType,
            signals: signals,
            calibrationDecision: baseCalibrationDecision,
            policy: policy
        )
        if dotSuppressedByLatency {
            policyContradictions.append(.latencyBudgetExceeded)
        }
        let calibrationDecision: GroundingCalibrationDecision = dotSuppressedByLatency
            ? .strongBlock
            : baseCalibrationDecision
        let preDotVerificationReasons = GroundingDotEligibilityPolicy.preDotVerificationReasons(
            guideResponse: guideResponse,
            target: observation.target,
            actionRisk: actionRisk,
            screenType: screenType,
            stageType: stageType,
            regionQuality: regionQuality,
            signals: signals,
            latency: latency,
            fastPathDecision: fastPathDecision,
            calibrationDecision: calibrationDecision,
            screenChanged: screenChanged,
            policy: policy
        )

        let evidence = GroundingSensorFusionEvidence(
            primaryVisionTargetId: guidePoint.targetElementId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            targetElementIdHash: observation.targetElementIdHash,
            targetFingerprint: observation.targetFingerprint,
            regionQuality: regionQuality,
            actionRisk: actionRisk,
            screenType: screenType,
            stageType: stageType,
            journeyDecision: journeyDecision,
            calibrationDecision: calibrationDecision,
            fastPathDecision: fastPathDecision,
            dotSuppressedByLatency: dotSuppressedByLatency,
            preDotVerificationReasons: preDotVerificationReasons,
            policyContradictions: policyContradictions,
            signals: signals,
            latency: latency
        )
        return GroundingSensorFusionDecisionResolver.resolve(
            from: evidence,
            policy: policy
        )
    }

    #if DEBUG
    static func decisionForTesting(
        signals: [GroundingAuxiliarySignal],
        targetElementIdHash: String? = "test-target-hash",
        targetFingerprint: TargetFingerprint? = TargetFingerprint(
            value: "test-target-fingerprint",
            compatibilityValue: "test-target-fingerprint-compat"
        ),
        regionQuality: RegionQuality = RegionQuality(
            regionConfidence: .high,
            regionSource: .vision,
            regionStability: .stable,
            regionPlausibility: .plausible,
            pointInsideRegionConfidence: .high
        ),
        actionRisk: GroundingActionRisk = .selection,
        screenType: GroundingScreenType = .cardTileSelection,
        stageType: GroundingStageType = .safeSetup,
        journeyDecision: GroundingJourneyDecision = GroundingJourneyDecision(transition: .sameScreen, allowsDot: true),
        preDotVerificationReasons: [GroundingPreDotVerificationReason] = [],
        policyContradictions: [GroundingSensorFusionContradiction] = [],
        fastPathDecision: GroundingFastPathDecision = .notEligible,
        dotSuppressedByLatency: Bool = false,
        latency: GroundingSensorFusionLatency = GroundingSensorFusionLatency(
            sensorFusionLatencyMs: 0,
            cursorMetadataLatencyMs: nil,
            ocrLatencyMs: nil,
            axLatencyMs: nil,
            browserMetadataLatencyMs: nil,
            totalPointDecisionLatencyMs: 0
        ),
        policy: GroundingSensorFusionPolicy = .default
    ) -> GroundingSensorFusionDecision {
        var normalizedPolicyContradictions = policyContradictions
        if dotSuppressedByLatency,
           !normalizedPolicyContradictions.contains(.latencyBudgetExceeded) {
            normalizedPolicyContradictions.append(.latencyBudgetExceeded)
        }
        let computedCalibrationDecision: GroundingCalibrationDecision
        if dotSuppressedByLatency {
            computedCalibrationDecision = .strongBlock
        } else {
            computedCalibrationDecision = GroundingDotEligibilityPolicy.calibrationDecision(
                actionRisk: actionRisk,
                screenType: screenType,
                stageType: stageType,
                regionQuality: regionQuality,
                signals: signals,
                policyContradictions: normalizedPolicyContradictions
            )
        }
        return GroundingSensorFusionDecisionResolver.resolve(
            from: GroundingSensorFusionEvidence(
                primaryVisionTargetId: "test-target",
                targetElementIdHash: targetElementIdHash,
                targetFingerprint: targetFingerprint,
                regionQuality: regionQuality,
                actionRisk: actionRisk,
                screenType: screenType,
                stageType: stageType,
                journeyDecision: journeyDecision,
                calibrationDecision: computedCalibrationDecision,
                fastPathDecision: fastPathDecision,
                dotSuppressedByLatency: dotSuppressedByLatency,
                preDotVerificationReasons: preDotVerificationReasons,
                policyContradictions: normalizedPolicyContradictions,
                signals: signals,
                latency: latency
            ),
            policy: policy
        )
    }

    static func localOCRSignalForTesting(
        expectedLabel: String,
        candidates: [GroundingOCRCandidate],
        policy: GroundingSensorFusionPolicy = .default
    ) -> GroundingAuxiliarySignal {
        GroundingLocalOCRSensor.signal(
            expectedLabel: expectedLabel,
            candidates: candidates,
            policy: policy
        )
    }

    static func signalForTesting(
        _ signal: GroundingAuxiliarySignal,
        applyingLatencyCutoffMs cutoffMs: Int,
        measuredLatencyMs: Int
    ) -> GroundingAuxiliarySignal {
        GroundingSensorFusionTiming.signalAfterApplyingLatencyCutoff(
            signal,
            cutoffMs: cutoffMs,
            measuredLatencyMs: measuredLatencyMs
        )
    }
    #endif

}
