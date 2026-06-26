//
//  CompanionGuidePointEvaluator.swift
//  leanring-buddy
//
//  Resolves whether a Worker-proposed guide point is eligible for overlay use.
//

import Foundation

struct CompanionGuidePointEvaluation {
    let point: SpiderGuidePoint?
    let rejectionReason: SpiderGuidePointRejectionReason?
    let sensorFusionDecision: GroundingSensorFusionDecision?
    let sensorFusionLatencyMs: Int?
}

enum CompanionGuidePointSensorFusionRejectionStyle {
    case policySpecific
    case genericContradiction

    func rejectionReason(for decision: GroundingSensorFusionDecision) -> SpiderGuidePointRejectionReason {
        switch self {
        case .policySpecific:
            return SpiderGuidePointSafetyPolicy.rejectionReason(for: decision)
        case .genericContradiction:
            return .sensorFusionContradicted
        }
    }
}

@MainActor
enum CompanionGuidePointEvaluator {
    static func evaluate(
        guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        screenCaptures: [CompanionScreenCapture],
        screenChanged: Bool,
        hasNegativeMemoryBlock: Bool = false,
        hasRepeatedFailedPointBlock: Bool = false,
        telemetryMetadata: GroundingTelemetryRecorder.GuideResponseMetadata,
        groundingTelemetryStartedAt: Date,
        screenshotCaptureLatencyMs: Int,
        visionRequestLatencyMs: Int,
        pollIndex: Int?,
        sensorFusionRejectionStyle: CompanionGuidePointSensorFusionRejectionStyle = .policySpecific
    ) async -> CompanionGuidePointEvaluation {
        let initialPointDecision = SpiderGuidePointSafetyPolicy.initialPointDecision(
            for: guideResponse,
            resolvedScreenState: resolvedScreenState,
            hasNegativeMemoryBlock: hasNegativeMemoryBlock,
            hasRepeatedFailedPointBlock: hasRepeatedFailedPointBlock
        )
        var pointRejectionReason = initialPointDecision.rejectionReason
        var sensorFusionDecision: GroundingSensorFusionDecision?
        var sensorFusionLatencyMs: Int?

        if let guidePoint = initialPointDecision.point,
           pointRejectionReason == nil {
            let sensorFusionResult = await CompanionGuidePointSensorFusionRunner.evaluate(
                guideResponse: guideResponse,
                guidePoint: guidePoint,
                screenCaptures: screenCaptures,
                screenChanged: screenChanged,
                telemetryMetadata: telemetryMetadata,
                groundingTelemetryStartedAt: groundingTelemetryStartedAt,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                pollIndex: pollIndex
            )
            let decision = sensorFusionResult.decision
            sensorFusionDecision = decision
            sensorFusionLatencyMs = sensorFusionResult.latencyMs
            if decision.shouldBlockPoint {
                pointRejectionReason = sensorFusionRejectionStyle.rejectionReason(for: decision)
            }
        }

        return CompanionGuidePointEvaluation(
            point: initialPointDecision.point,
            rejectionReason: pointRejectionReason,
            sensorFusionDecision: sensorFusionDecision,
            sensorFusionLatencyMs: sensorFusionLatencyMs
        )
    }
}
