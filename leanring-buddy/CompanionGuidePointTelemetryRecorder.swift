//
//  CompanionGuidePointTelemetryRecorder.swift
//  leanring-buddy
//
//  Companion-level guide point telemetry. This keeps the main manager from
//  knowing the accepted/rejected/suppressed event details.
//

import Foundation

struct CompanionGuidePointAcceptedTelemetry {
    let pointMetadata: GroundingTelemetryRecorder.PointAcceptanceMetadata
    let timeToDotMs: Int
}

enum CompanionGuidePointTelemetryRecorder {
    static func recordAccepted(
        guidePoint: SpiderGuidePoint,
        metadata: GroundingTelemetryRecorder.GuideResponseMetadata,
        sensorFusionDecision: GroundingSensorFusionDecision?,
        groundingTelemetryStartedAt: Date,
        screenshotCaptureLatencyMs: Int?,
        visionRequestLatencyMs: Int?,
        screenChanged: Bool,
        pollIndex: Int?,
        now: Date = Date()
    ) -> CompanionGuidePointAcceptedTelemetry {
        let timeToDotMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: groundingTelemetryStartedAt,
            now: now
        )
        let pointMetadata = GroundingTelemetryRecorder.pointAcceptanceMetadata(
            for: guidePoint,
            sensorFusionDecision: sensorFusionDecision
        )
        GroundingTelemetryRecorder.recordPointAccepted(
            metadata: metadata,
            pointMetadata: pointMetadata,
            latencyMs: timeToDotMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            timeToDotMs: timeToDotMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            sensorFusionDecision: sensorFusionDecision
        )
        return CompanionGuidePointAcceptedTelemetry(
            pointMetadata: pointMetadata,
            timeToDotMs: timeToDotMs
        )
    }

    static func recordRejected(
        reason: SpiderGuidePointRejectionReason,
        platform: SpiderAdPlatformID,
        guideResponse: SpiderGuideResponse?,
        resolvedScreenState: SpiderGuideScreenState?,
        retryPolicy: GroundingRetryPolicy?,
        latencyMs: Int?,
        screenshotCaptureLatencyMs: Int?,
        visionRequestLatencyMs: Int?,
        preDotVerificationLatencyMs: Int? = nil,
        screenChanged: Bool?,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision?
    ) {
        GroundingTelemetryRecorder.recordGuidePointRejection(
            reason: reason,
            platform: platform,
            guideResponse: guideResponse,
            resolvedScreenState: resolvedScreenState,
            retryPolicy: retryPolicy,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            preDotVerificationLatencyMs: preDotVerificationLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            sensorFusionDecision: sensorFusionDecision
        )
    }

    static func recordSuppressed(
        metadata: GroundingTelemetryRecorder.GuideResponseMetadata,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int?,
        visionRequestLatencyMs: Int?,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        GroundingTelemetryRecorder.recordPointSuppressed(
            metadata: metadata,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
    }
}
