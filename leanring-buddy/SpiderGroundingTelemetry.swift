//
//  SpiderGroundingTelemetry.swift
//  leanring-buddy
//
//  Typed, privacy-safe grounding telemetry contracts. Payloads are allowlisted
//  and deliberately exclude screenshots, transcripts, prompts, model responses,
//  email addresses, raw UI text, and tokens.
//

import Foundation

enum SpiderGroundingTelemetryEventName: String {
    case frameAnalyzed = "grounding_frame_analyzed"
    case pointAccepted = "grounding_point_accepted"
    case pointRejected = "grounding_point_rejected"
    case outcomeEvaluated = "grounding_outcome_evaluated"
    case pointSuppressed = "grounding_point_suppressed"
    case sensorFusionEvaluated = "grounding_sensor_fusion_evaluated"
    case shadowCandidate = "grounding_shadow_candidate"
}

struct SpiderGroundingTelemetryEvent: Equatable {
    let name: SpiderGroundingTelemetryEventName
    let platform: SpiderAdPlatformID
    let stageId: String?
    let screenState: SpiderGuideScreenState?
    let screenConfidence: SpiderGuideConfidence?
    let semanticSignature: String?
    let targetElementIdHash: String?
    let expectedOutcome: SpiderGuideExpectedOutcome?
    let rejectionReason: SpiderGuidePointRejectionReason?
    let outcomeStatus: GuidedPointOutcomeStatus?
    let latencyMs: Int?
    let screenshotCaptureLatencyMs: Int?
    let visionRequestLatencyMs: Int?
    let workerValidationLatencyMs: Int?
    let preDotVerificationLatencyMs: Int?
    let timeToDotMs: Int?
    let dotSuppressedByLatency: Bool?
    let screenChanged: Bool?
    let pollIndex: Int?
    let retryPolicy: GroundingRetryPolicy?
    let sensorFusionDecision: GroundingSensorFusionDecision?
    let wouldHaveShownDot: Bool?
    let timestamp: Date
    let appVersion: String?
    let groundingSchemaVersion: Int

    init(
        name: SpiderGroundingTelemetryEventName,
        platform: SpiderAdPlatformID,
        stageId: String?,
        screenState: SpiderGuideScreenState?,
        screenConfidence: SpiderGuideConfidence?,
        semanticSignature: String?,
        targetElementIdHash: String?,
        expectedOutcome: SpiderGuideExpectedOutcome?,
        rejectionReason: SpiderGuidePointRejectionReason?,
        outcomeStatus: GuidedPointOutcomeStatus?,
        latencyMs: Int?,
        screenshotCaptureLatencyMs: Int? = nil,
        visionRequestLatencyMs: Int? = nil,
        workerValidationLatencyMs: Int? = nil,
        preDotVerificationLatencyMs: Int? = nil,
        timeToDotMs: Int? = nil,
        dotSuppressedByLatency: Bool? = nil,
        screenChanged: Bool?,
        pollIndex: Int?,
        retryPolicy: GroundingRetryPolicy?,
        sensorFusionDecision: GroundingSensorFusionDecision?,
        wouldHaveShownDot: Bool?,
        timestamp: Date,
        appVersion: String?,
        groundingSchemaVersion: Int
    ) {
        self.name = name
        self.platform = platform
        self.stageId = stageId
        self.screenState = screenState
        self.screenConfidence = screenConfidence
        self.semanticSignature = semanticSignature
        self.targetElementIdHash = targetElementIdHash
        self.expectedOutcome = expectedOutcome
        self.rejectionReason = rejectionReason
        self.outcomeStatus = outcomeStatus
        self.latencyMs = latencyMs
        self.screenshotCaptureLatencyMs = screenshotCaptureLatencyMs
        self.visionRequestLatencyMs = visionRequestLatencyMs
        self.workerValidationLatencyMs = workerValidationLatencyMs
        self.preDotVerificationLatencyMs = preDotVerificationLatencyMs
        self.timeToDotMs = timeToDotMs
        self.dotSuppressedByLatency = dotSuppressedByLatency
        self.screenChanged = screenChanged
        self.pollIndex = pollIndex
        self.retryPolicy = retryPolicy
        self.sensorFusionDecision = sensorFusionDecision
        self.wouldHaveShownDot = wouldHaveShownDot
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.groundingSchemaVersion = groundingSchemaVersion
    }

    var sanitizedPayload: [String: String] {
        SpiderGroundingTelemetryPayloadBuilder.sanitizedPayload(for: self)
    }
}
