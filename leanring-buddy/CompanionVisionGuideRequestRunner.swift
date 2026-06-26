//
//  CompanionVisionGuideRequestRunner.swift
//  leanring-buddy
//
//  Runs the Worker-backed vision-guide request setup for CompanionManager.
//  Screenshots remain in memory only; telemetry receives metadata-safe values.
//

import Foundation

enum CompanionVisionGuideRequestRunnerError: Error {
    case emptyScreenCapture
}

struct CompanionVisionGuideRequestResult {
    let guideResponse: SpiderGuideResponse
    let screenCaptures: [CompanionScreenCapture]
    let screenSignature: String
    let screenChanged: Bool
    let resolvedScreenState: SpiderGuideScreenState
    let telemetryMetadata: GroundingTelemetryRecorder.GuideResponseMetadata
    let groundingTelemetryStartedAt: Date
    let groundingTelemetryLatencyMs: Int
    let screenshotCaptureLatencyMs: Int
    let visionRequestLatencyMs: Int
}

@MainActor
enum CompanionVisionGuideRequestRunner {
    static func run(
        transcript: String,
        guideClient: OpenAIVisionGuideClient,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        adMissionSnapshot: AdMission,
        platformContext: SpiderPlatformContext?,
        platformId: SpiderAdPlatformID,
        guidedSetupSession: GuidedSetupSession?,
        guidedSetupPollIndex: Int?,
        appLanguage: String
    ) async throws -> CompanionVisionGuideRequestResult {
        let groundingTelemetryStartedAt = Date()
        let screenshotCaptureStartedAt = Date()
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let screenshotCaptureLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: screenshotCaptureStartedAt
        )
        guard !screenCaptures.isEmpty else {
            throw CompanionVisionGuideRequestRunnerError.emptyScreenCapture
        }
        try Task.checkCancellation()

        let guideRequestContext = CompanionGuideRequestContextBuilder.build(
            transcript: transcript,
            screenCaptures: screenCaptures,
            guidedSetupSession: guidedSetupSession,
            guidedSetupPollIndex: guidedSetupPollIndex
        )
        let visionRequestStartedAt = Date()
        let guideResponse = try await guideClient.guide(
            userTranscript: guideRequestContext.outboundTranscript,
            screenCaptures: screenCaptures,
            conversationHistory: conversationHistory,
            adMissionSnapshot: adMissionSnapshot,
            platformContext: platformContext,
            guidedSessionContext: guideRequestContext.guidedSessionContext,
            appLanguage: appLanguage
        )
        try Task.checkCancellation()

        let visionRequestLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: visionRequestStartedAt
        )
        let resolvedScreenState = GuideResponsePresentationPolicy.resolvedScreenState(
            for: guideResponse
        )
        let groundingTelemetryLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: groundingTelemetryStartedAt
        )
        let telemetryMetadata = GroundingTelemetryRecorder.guideResponseMetadata(
            platform: platformId,
            guideResponse: guideResponse,
            resolvedScreenState: resolvedScreenState
        )
        GroundingTelemetryRecorder.recordFrameAnalyzed(
            metadata: telemetryMetadata,
            latencyMs: groundingTelemetryLatencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: guideRequestContext.screenChanged,
            pollIndex: guidedSetupPollIndex
        )
        SpiderAnalytics.trackGuideScreenClassified(
            screenState: resolvedScreenState,
            confidence: telemetryMetadata.screenConfidence
        )

        return CompanionVisionGuideRequestResult(
            guideResponse: guideResponse,
            screenCaptures: screenCaptures,
            screenSignature: guideRequestContext.screenSignature,
            screenChanged: guideRequestContext.screenChanged,
            resolvedScreenState: resolvedScreenState,
            telemetryMetadata: telemetryMetadata,
            groundingTelemetryStartedAt: groundingTelemetryStartedAt,
            groundingTelemetryLatencyMs: groundingTelemetryLatencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs
        )
    }
}
