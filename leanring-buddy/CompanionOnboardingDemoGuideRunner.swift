//
//  CompanionOnboardingDemoGuideRunner.swift
//  leanring-buddy
//
//  Runs the screen-first guide request used by the onboarding demo. The runner
//  keeps screenshot capture, Worker transport, and point evaluation outside the
//  CompanionManager UI state machine.
//

import Foundation

enum CompanionOnboardingDemoGuideRunnerError: Error {
    case emptyScreenCapture
    case cursorScreenUnavailable
}

struct CompanionOnboardingDemoGuideResult {
    let guideResponse: SpiderGuideResponse
    let cursorScreenCapture: CompanionScreenCapture
    let resolvedScreenState: SpiderGuideScreenState
    let telemetryMetadata: GroundingTelemetryRecorder.GuideResponseMetadata
    let pointEvaluation: CompanionGuidePointEvaluation
    let groundingTelemetryStartedAt: Date
    let groundingTelemetryLatencyMs: Int
    let screenshotCaptureLatencyMs: Int
    let visionRequestLatencyMs: Int
}

enum CompanionOnboardingDemoGuidePrompt {
    static let transcript = "Look at this ads screen and point at the single most useful setup issue I should understand next. Do not publish or change spend."
}

@MainActor
enum CompanionOnboardingDemoGuideRunner {
    static func run(
        guideClient: OpenAIVisionGuideClient,
        adMissionSnapshot: AdMission,
        platformContext: SpiderPlatformContext?,
        platformId: SpiderAdPlatformID,
        appLanguage: String
    ) async throws -> CompanionOnboardingDemoGuideResult {
        let groundingTelemetryStartedAt = Date()
        let screenshotCaptureStartedAt = Date()
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let screenshotCaptureLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: screenshotCaptureStartedAt
        )
        guard !screenCaptures.isEmpty else {
            throw CompanionOnboardingDemoGuideRunnerError.emptyScreenCapture
        }
        guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
            throw CompanionOnboardingDemoGuideRunnerError.cursorScreenUnavailable
        }
        try Task.checkCancellation()

        let visionRequestStartedAt = Date()
        let guideResponse = try await guideClient.guide(
            userTranscript: CompanionOnboardingDemoGuidePrompt.transcript,
            screenCaptures: [cursorScreenCapture],
            conversationHistory: [],
            adMissionSnapshot: adMissionSnapshot,
            platformContext: platformContext,
            appLanguage: appLanguage
        )
        try Task.checkCancellation()

        let visionRequestLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: visionRequestStartedAt
        )
        let resolvedScreenState = GuideResponsePresentationPolicy.resolvedScreenState(
            for: guideResponse
        )
        let frameAnalyzedLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
            since: groundingTelemetryStartedAt
        )
        let telemetryMetadata = GroundingTelemetryRecorder.guideResponseMetadata(
            platform: platformId,
            guideResponse: guideResponse,
            resolvedScreenState: resolvedScreenState
        )
        GroundingTelemetryRecorder.recordFrameAnalyzed(
            metadata: telemetryMetadata,
            latencyMs: frameAnalyzedLatencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            screenChanged: true,
            pollIndex: nil
        )

        let pointEvaluation = await CompanionGuidePointEvaluator.evaluate(
            guideResponse: guideResponse,
            resolvedScreenState: resolvedScreenState,
            screenCaptures: [cursorScreenCapture],
            screenChanged: true,
            telemetryMetadata: telemetryMetadata,
            groundingTelemetryStartedAt: groundingTelemetryStartedAt,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs,
            pollIndex: nil,
            sensorFusionRejectionStyle: .genericContradiction
        )

        return CompanionOnboardingDemoGuideResult(
            guideResponse: guideResponse,
            cursorScreenCapture: cursorScreenCapture,
            resolvedScreenState: resolvedScreenState,
            telemetryMetadata: telemetryMetadata,
            pointEvaluation: pointEvaluation,
            groundingTelemetryStartedAt: groundingTelemetryStartedAt,
            groundingTelemetryLatencyMs: pointEvaluation.sensorFusionLatencyMs ?? frameAnalyzedLatencyMs,
            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
            visionRequestLatencyMs: visionRequestLatencyMs
        )
    }
}
