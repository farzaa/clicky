//
//  GroundingSensorFusionSignalCollector.swift
//  leanring-buddy
//
//  Collects privacy-safe local signals for a Vision-selected guide point.
//  It never creates or authorizes points; GroundingSensorFusion keeps the dot
//  eligibility and final decision policy.
//

import Foundation

struct GroundingSensorFusionObservation {
    let target: SpiderGuideSemanticTarget?
    let targetElementIdHash: String?
    let targetFingerprint: TargetFingerprint?
    let regionQuality: RegionQuality
    let contextClassification: GroundingContextClassification
    let quickSignals: [GroundingAuxiliarySignal]
    let signals: [GroundingAuxiliarySignal]
    let fastPathEligibleBeforeOCR: Bool
    let latency: GroundingSensorFusionLatency
}

@MainActor
enum GroundingSensorFusionSignalCollector {
    static func collect(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture],
        browserMetadata: GroundingBrowserMetadata?,
        screenChanged: Bool,
        policy: GroundingSensorFusionPolicy,
        evaluationStartedAt: Date
    ) -> GroundingSensorFusionObservation {
        let projection = GroundingPointProjector.projection(for: guidePoint, in: screenCaptures)
        let target = guideResponse.semanticGrounding?.target(matching: guidePoint)
        let element = guideResponse.semanticGrounding?.element(matching: target)
        let targetElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: guidePoint.targetElementId)
        let targetFingerprint = TargetFingerprint.make(
            target: target,
            grounding: guideResponse.semanticGrounding,
            stageId: guideResponse.stageId,
            expectedOutcome: guidePoint.expectedOutcome
        )
        let regionQuality = GroundingRegionQualityEvaluator.evaluate(
            guidePoint: guidePoint,
            projection: projection,
            grounding: guideResponse.semanticGrounding,
            target: target,
            element: element,
            policy: policy
        )
        let contextClassification = GroundingContextClassifier.classify(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            target: target
        )

        let axSnapshotMeasurement = GroundingSensorFusionTiming.measureOptional(
            source: .macOSAccessibility,
            cutoffMs: policy.axDeadlineMs
        ) {
            projection.flatMap {
                GroundingAccessibilitySensor.snapshot(
                    at: $0.displayPoint,
                    in: $0.capture.displayFrame,
                    policy: policy
                )
            }
        }

        let browserMetadataMeasurement = GroundingSensorFusionTiming.measureValue(
            source: .browserMetadata,
            cutoffMs: policy.browserDeadlineMs
        ) {
            browserMetadata ?? GroundingAccessibilitySensor.browserMetadata(from: axSnapshotMeasurement.value)
        }

        let cursorSignal = GroundingSensorFusionTiming.measureSignal(source: .cursorMetadata, cutoffMs: nil) {
            GroundingCursorMetadataSensor.signal(
                guidePoint: guidePoint,
                projection: projection,
                grounding: guideResponse.semanticGrounding,
                target: target,
                element: element,
                targetFingerprint: targetFingerprint,
                regionQuality: regionQuality,
                screenChanged: screenChanged,
                policy: policy
            )
        }
        let axSignal = GroundingSensorFusionTiming.signalAfterApplyingLatencyCutoff(
            GroundingAccessibilitySensor.accessibilitySignal(axSnapshotMeasurement.value),
            cutoffMs: policy.axDeadlineMs,
            measuredLatencyMs: axSnapshotMeasurement.latencyMs
        )
        let browserSignal = GroundingSensorFusionTiming.signalAfterApplyingLatencyCutoff(
            GroundingAccessibilitySensor.browserMetadataSignal(browserMetadataMeasurement.value),
            cutoffMs: policy.browserDeadlineMs,
            measuredLatencyMs: browserMetadataMeasurement.latencyMs
        )
        let quickSignals = [cursorSignal, axSignal, browserSignal]
        let fastPathEligibleBeforeOCR = GroundingDotEligibilityPolicy.isFastPathEligible(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            target: target,
            targetFingerprint: targetFingerprint,
            actionRisk: contextClassification.actionRisk,
            screenType: contextClassification.screenType,
            stageType: contextClassification.stageType,
            regionQuality: regionQuality,
            quickSignals: quickSignals,
            screenChanged: screenChanged
        )
        let ocrSignal: GroundingAuxiliarySignal
        if fastPathEligibleBeforeOCR {
            ocrSignal = .unavailable(.localOCR, latencyMs: 0)
        } else {
            ocrSignal = GroundingSensorFusionTiming.measureSignal(source: .localOCR, cutoffMs: policy.ocrDeadlineMs) {
                GroundingLocalOCRSensor.signal(
                    guidePoint: guidePoint,
                    projection: projection,
                    target: target,
                    policy: policy
                )
            }
        }
        let signals = [
            cursorSignal,
            ocrSignal,
            axSignal,
            browserSignal,
        ]
        let totalDecisionLatencyMs = GroundingSensorFusionTiming.elapsedMilliseconds(since: evaluationStartedAt)
        let latency = GroundingSensorFusionLatency(
            sensorFusionLatencyMs: totalDecisionLatencyMs,
            cursorMetadataLatencyMs: signals.first(where: { $0.source == .cursorMetadata })?.latencyMs,
            ocrLatencyMs: signals.first(where: { $0.source == .localOCR })?.latencyMs,
            axLatencyMs: signals.first(where: { $0.source == .macOSAccessibility })?.latencyMs,
            browserMetadataLatencyMs: signals.first(where: { $0.source == .browserMetadata })?.latencyMs,
            totalPointDecisionLatencyMs: totalDecisionLatencyMs
        )

        return GroundingSensorFusionObservation(
            target: target,
            targetElementIdHash: targetElementIdHash,
            targetFingerprint: targetFingerprint,
            regionQuality: regionQuality,
            contextClassification: contextClassification,
            quickSignals: quickSignals,
            signals: signals,
            fastPathEligibleBeforeOCR: fastPathEligibleBeforeOCR,
            latency: latency
        )
    }
}
