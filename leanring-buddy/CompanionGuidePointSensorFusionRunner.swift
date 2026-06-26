//
//  CompanionGuidePointSensorFusionRunner.swift
//  leanring-buddy
//
//  Runs local sensor fusion for an already gate-approved guide point and records
//  its privacy-safe telemetry. It does not decide whether the point is initially
//  eligible; CompanionGuidePointEvaluator owns that boundary.
//

import Foundation

struct CompanionGuidePointSensorFusionResult {
    let decision: GroundingSensorFusionDecision
    let latencyMs: Int
}

@MainActor
enum CompanionGuidePointSensorFusionRunner {
    static func evaluate(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture],
        screenChanged: Bool,
        telemetryMetadata: GroundingTelemetryRecorder.GuideResponseMetadata,
        groundingTelemetryStartedAt: Date,
        screenshotCaptureLatencyMs: Int,
        visionRequestLatencyMs: Int,
        pollIndex: Int?
    ) async -> CompanionGuidePointSensorFusionResult {
        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            screenCaptures: screenCaptures,
            screenChanged: screenChanged
        )
        let latencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(since: groundingTelemetryStartedAt)
        GroundingTelemetryRecorder.recordSensorFusionEvaluated(
            metadata: telemetryMetadata,
            targetElementIdHash: decision.targetElementIdHash,
            expectedOutcome: guidePoint.expectedOutcome,
            sensorFusionDecision: decision,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
        return CompanionGuidePointSensorFusionResult(
            decision: decision,
            latencyMs: latencyMs
        )
    }
}
