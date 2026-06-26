//
//  SpiderGroundingAnalytics.swift
//  leanring-buddy
//
//  Privacy-safe grounding telemetry emitters. These APIs only accept typed,
//  sanitized metadata and never accept screenshots, transcripts, prompts,
//  model responses, raw UI text, email addresses, or tokens.
//

import Foundation

extension SpiderAnalytics {
    static func trackGroundingFrameAnalyzed(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState,
        screenConfidence: SpiderGuideConfidence,
        semanticSignature: String?,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .frameAnalyzed,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: nil,
                expectedOutcome: nil,
                rejectionReason: nil,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: nil,
                sensorFusionDecision: nil,
                wouldHaveShownDot: nil,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingPointAccepted(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState,
        screenConfidence: SpiderGuideConfidence,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        timeToDotMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision? = nil
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .pointAccepted,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: targetElementIdHash,
                expectedOutcome: expectedOutcome,
                rejectionReason: nil,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                timeToDotMs: timeToDotMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: nil,
                sensorFusionDecision: sensorFusionDecision,
                wouldHaveShownDot: true,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingPointRejected(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState?,
        screenConfidence: SpiderGuideConfidence?,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        rejectionReason: SpiderGuidePointRejectionReason,
        retryPolicy: GroundingRetryPolicy?,
        latencyMs: Int?,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        preDotVerificationLatencyMs: Int? = nil,
        screenChanged: Bool?,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision? = nil
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .pointRejected,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: targetElementIdHash,
                expectedOutcome: expectedOutcome,
                rejectionReason: rejectionReason,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: retryPolicy,
                sensorFusionDecision: sensorFusionDecision,
                wouldHaveShownDot: true,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingOutcomeEvaluated(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState,
        screenConfidence: SpiderGuideConfidence,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        outcomeStatus: GuidedPointOutcomeStatus,
        retryPolicy: GroundingRetryPolicy?,
        latencyMs: Int?,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .outcomeEvaluated,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: targetElementIdHash,
                expectedOutcome: expectedOutcome,
                rejectionReason: nil,
                outcomeStatus: outcomeStatus,
                latencyMs: latencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: retryPolicy,
                sensorFusionDecision: nil,
                wouldHaveShownDot: nil,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingPointSuppressed(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState,
        screenConfidence: SpiderGuideConfidence,
        semanticSignature: String?,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .pointSuppressed,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: nil,
                expectedOutcome: nil,
                rejectionReason: nil,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: nil,
                sensorFusionDecision: nil,
                wouldHaveShownDot: false,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingSensorFusionEvaluated(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState,
        screenConfidence: SpiderGuideConfidence,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        sensorFusionDecision: GroundingSensorFusionDecision,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        screenChanged: Bool,
        pollIndex: Int?
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .sensorFusionEvaluated,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: targetElementIdHash,
                expectedOutcome: expectedOutcome,
                rejectionReason: nil,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: nil,
                sensorFusionDecision: sensorFusionDecision,
                wouldHaveShownDot: nil,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }

    static func trackGroundingShadowCandidate(
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState?,
        screenConfidence: SpiderGuideConfidence?,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        rejectionReason: SpiderGuidePointRejectionReason,
        latencyMs: Int?,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        preDotVerificationLatencyMs: Int? = nil,
        screenChanged: Bool?,
        pollIndex: Int?,
        sensorFusionDecision: GroundingSensorFusionDecision?
    ) {
        guard SpiderGroundingTelemetryEmitter.isEnabled else {
            return
        }

        SpiderGroundingTelemetryEmitter.emit(
            SpiderGroundingTelemetryEvent(
                name: .shadowCandidate,
                platform: platform,
                stageId: stageId,
                screenState: screenState,
                screenConfidence: screenConfidence,
                semanticSignature: semanticSignature,
                targetElementIdHash: targetElementIdHash,
                expectedOutcome: expectedOutcome,
                rejectionReason: rejectionReason,
                outcomeStatus: nil,
                latencyMs: latencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                workerValidationLatencyMs: workerValidationLatencyMs,
                preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                retryPolicy: nil,
                sensorFusionDecision: sensorFusionDecision,
                wouldHaveShownDot: true,
                timestamp: Date(),
                appVersion: SpiderGroundingTelemetryEmitter.safeAppVersion,
                groundingSchemaVersion: SpiderGroundingTelemetryEmitter.groundingSchemaVersion
            )
        )
    }
}
