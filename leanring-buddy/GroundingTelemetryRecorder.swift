//
//  GroundingTelemetryRecorder.swift
//  leanring-buddy
//
//  Typed grounding telemetry emission helpers. This layer only forwards
//  metadata-safe values to SpiderAnalytics.
//

import Foundation

enum GroundingTelemetryRecorder {
    typealias GuideResponseMetadata = GroundingGuideResponseMetadata
    typealias PointRejectionMetadata = GroundingPointRejectionMetadata
    typealias PointAcceptanceMetadata = GroundingPointAcceptanceMetadata

    static func guideResponseMetadata(
        platform: SpiderAdPlatformID,
        guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState
    ) -> GuideResponseMetadata {
        GroundingTelemetryMetadataBuilder.guideResponseMetadata(
            platform: platform,
            guideResponse: guideResponse,
            resolvedScreenState: resolvedScreenState
        )
    }

    static func recordFrameAnalyzed(
        metadata: GuideResponseMetadata,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        SpiderAnalytics.trackGroundingFrameAnalyzed(
            platform: metadata.platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
    }

    static func recordSensorFusionEvaluated(
        metadata: GuideResponseMetadata,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        sensorFusionDecision: GroundingSensorFusionDecision,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        SpiderAnalytics.trackGroundingSensorFusionEvaluated(
            platform: metadata.platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            targetElementIdHash: targetElementIdHash,
            expectedOutcome: expectedOutcome,
            sensorFusionDecision: sensorFusionDecision,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
    }

    static func recordPointAccepted(
        metadata: GuideResponseMetadata,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        timeToDotMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision? = nil
    ) {
        SpiderAnalytics.trackGroundingPointAccepted(
            platform: metadata.platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            targetElementIdHash: targetElementIdHash,
            expectedOutcome: expectedOutcome,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            timeToDotMs: timeToDotMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            sensorFusionDecision: sensorFusionDecision
        )
    }

    static func pointAcceptanceMetadata(
        for guidePoint: SpiderGuidePoint,
        sensorFusionDecision: GroundingSensorFusionDecision?
    ) -> PointAcceptanceMetadata {
        GroundingTelemetryMetadataBuilder.pointAcceptanceMetadata(
            for: guidePoint,
            sensorFusionDecision: sensorFusionDecision
        )
    }

    static func recordPointAccepted(
        metadata: GuideResponseMetadata,
        pointMetadata: PointAcceptanceMetadata,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        timeToDotMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision? = nil
    ) {
        recordPointAccepted(
            metadata: metadata,
            targetElementIdHash: pointMetadata.targetElementIdHash,
            expectedOutcome: pointMetadata.expectedOutcome,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            timeToDotMs: timeToDotMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            sensorFusionDecision: sensorFusionDecision
        )
    }

    static func recordPointSuppressed(
        metadata: GuideResponseMetadata,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        SpiderAnalytics.trackGroundingPointSuppressed(
            platform: metadata.platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
    }

    static func recordOutcomeEvaluated(
        metadata: GuideResponseMetadata,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        outcomeStatus: GuidedPointOutcomeStatus,
        retryPolicy: GroundingRetryPolicy?,
        latencyMs: Int?,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        SpiderAnalytics.trackGroundingOutcomeEvaluated(
            platform: metadata.platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            targetElementIdHash: targetElementIdHash,
            expectedOutcome: expectedOutcome,
            outcomeStatus: outcomeStatus,
            retryPolicy: retryPolicy,
            latencyMs: latencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex
        )
    }

    static func pointRejectionMetadata(
        for guideResponse: SpiderGuideResponse?,
        resolvedScreenState: SpiderGuideScreenState?,
        retryPolicy: GroundingRetryPolicy?
    ) -> PointRejectionMetadata? {
        GroundingTelemetryMetadataBuilder.pointRejectionMetadata(
            for: guideResponse,
            resolvedScreenState: resolvedScreenState,
            retryPolicy: retryPolicy
        )
    }

    static func shouldTrackShadowCandidate(for guideResponse: SpiderGuideResponse?) -> Bool {
        GroundingTelemetryMetadataBuilder.shouldTrackShadowCandidate(for: guideResponse)
    }

    static func recordGuidePointRejection(
        reason: SpiderGuidePointRejectionReason,
        platform: SpiderAdPlatformID,
        guideResponse: SpiderGuideResponse? = nil,
        resolvedScreenState: SpiderGuideScreenState? = nil,
        retryPolicy: GroundingRetryPolicy? = nil,
        latencyMs: Int? = nil,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        preDotVerificationLatencyMs: Int? = nil,
        screenChanged: Bool? = nil,
        pollIndex: Int? = nil,
        sensorFusionDecision: GroundingSensorFusionDecision? = nil
    ) {
        SpiderAnalytics.trackGuidePointRejected(reason: reason)

        guard let metadata = pointRejectionMetadata(
            for: guideResponse,
            resolvedScreenState: resolvedScreenState,
            retryPolicy: retryPolicy
        ) else {
            SpiderDiagnostics.guidePointIgnored(reason)
            return
        }

        SpiderAnalytics.trackGroundingPointRejected(
            platform: platform,
            stageId: metadata.stageId,
            screenState: metadata.screenState,
            screenConfidence: metadata.screenConfidence,
            semanticSignature: metadata.semanticSignature,
            targetElementIdHash: metadata.targetElementIdHash,
            expectedOutcome: metadata.expectedOutcome,
            rejectionReason: reason,
            retryPolicy: metadata.retryPolicy,
            latencyMs: latencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            preDotVerificationLatencyMs: preDotVerificationLatencyMs,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            sensorFusionDecision: sensorFusionDecision
        )

        if shouldTrackShadowCandidate(for: guideResponse) {
            SpiderAnalytics.trackGroundingShadowCandidate(
                platform: platform,
                stageId: metadata.stageId,
                screenState: metadata.screenState,
                screenConfidence: metadata.screenConfidence,
                semanticSignature: metadata.semanticSignature,
                targetElementIdHash: metadata.targetElementIdHash,
                expectedOutcome: metadata.expectedOutcome,
                rejectionReason: reason,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                sensorFusionDecision: sensorFusionDecision
            )
        }

        SpiderDiagnostics.guidePointIgnored(reason)
    }
}
