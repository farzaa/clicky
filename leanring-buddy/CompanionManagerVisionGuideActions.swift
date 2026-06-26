//
//  CompanionManagerVisionGuideActions.swift
//  leanring-buddy
//
//  Worker-backed Vision guide orchestration for CompanionManager. It preserves
//  the screen-first point gating path while keeping the main manager focused on
//  state ownership and shortcut lifecycle.
//

import Foundation

private struct CompanionVisionGuidePointApplicationResult {
    let acceptedPoint: SpiderGuidePoint?
    let acceptedPointMetadata: GroundingTelemetryRecorder.PointAcceptanceMetadata?
    let latencyMs: Int
}

@MainActor
extension CompanionManager {
    /// Captures screenshots, sends them with the transcript to the Spider Worker,
    /// and applies the structured visual guide response to voice + overlay.
    func sendTranscriptToSpiderGuideWithScreenshot(
        transcript: String,
        platformContext: SpiderPlatformContext? = nil,
        cancelsGuidedSetupPolling: Bool = true,
        cancelsCurrentResponse: Bool = true,
        isAutomaticScreenRefresh: Bool = false,
        guidedSetupPollIndex: Int? = nil
    ) {
        guard handleInteractionReadiness(
            CompanionInteractionReadinessPolicy.accountReadiness(
                accountCanUseAI: accountState.canUseAI
            )
        ) else { return }
        refreshAllPermissions()
        guard handleInteractionReadiness(
            CompanionInteractionReadinessPolicy.screenGuidancePermissionReadiness(
                hasScreenGuidancePermissions: hasScreenGuidancePermissions
            )
        ) else { return }

        if cancelsGuidedSetupPolling {
            guidedSetupPollScheduler.cancelPendingPoll()
            guidedSetupSession = nil
            clearGuidanceStatusBubble()
        }

        if !cancelsCurrentResponse && isVisionGuideRequestInFlight {
            SpiderDiagnostics.event("automatic screen refresh skipped because guide is in flight")
            return
        }

        if cancelsCurrentResponse {
            currentResponseTask?.cancel()
            isVisionGuideRequestInFlight = false
            speechPlaybackController.stopAllSpeech()
        }

        currentResponseTask = Task {
            isVisionGuideRequestInFlight = true
            defer {
                isVisionGuideRequestInFlight = false
                currentResponseTask = nil
            }

            setVoiceState(.processing)
            var willSpeakGuidance = false

            do {
                try await validateAIEntitlementBeforeScreenCapture()
                guard !Task.isCancelled else { return }

                let guideRequestResult = try await CompanionVisionGuideRequestRunner.run(
                    transcript: transcript,
                    guideClient: spiderVisionGuideClient,
                    conversationHistory: guideConversationTurns,
                    adMissionSnapshot: adMission,
                    platformContext: platformContext ?? currentPlatformContextForGuide(),
                    platformId: currentPlatformIdForGuide(),
                    guidedSetupSession: guidedSetupSession,
                    guidedSetupPollIndex: guidedSetupPollIndex,
                    appLanguage: SpiderUserPreferences.appLanguage
                )
                guard !Task.isCancelled else { return }
                let guideResponse = guideRequestResult.guideResponse
                let screenCaptures = guideRequestResult.screenCaptures
                let screenSignature = guideRequestResult.screenSignature
                let guidedSetupScreenChanged = guideRequestResult.screenChanged
                let resolvedGuideScreenState = guideRequestResult.resolvedScreenState
                let groundingTelemetryMetadata = guideRequestResult.telemetryMetadata
                let groundingTelemetryStartedAt = guideRequestResult.groundingTelemetryStartedAt
                let screenshotCaptureLatencyMs = guideRequestResult.screenshotCaptureLatencyMs
                let visionRequestLatencyMs = guideRequestResult.visionRequestLatencyMs
                var groundingTelemetryLatencyMs = guideRequestResult.groundingTelemetryLatencyMs

                let pointEvaluation = await CompanionGuidePointEvaluator.evaluate(
                    guideResponse: guideResponse,
                    resolvedScreenState: resolvedGuideScreenState,
                    screenCaptures: screenCaptures,
                    screenChanged: guidedSetupScreenChanged,
                    hasNegativeMemoryBlock: guidedSetupSession?.shouldRejectNegativeMemory(guideResponse) == true,
                    hasRepeatedFailedPointBlock: guidedSetupSession?.shouldRejectRepeatedFailedPoint(guideResponse) == true,
                    telemetryMetadata: groundingTelemetryMetadata,
                    groundingTelemetryStartedAt: groundingTelemetryStartedAt,
                    screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                    visionRequestLatencyMs: visionRequestLatencyMs,
                    pollIndex: guidedSetupPollIndex
                )
                var pointRejectionReason = pointEvaluation.rejectionReason
                let sensorFusionDecision = pointEvaluation.sensorFusionDecision
                if let sensorFusionLatencyMs = pointEvaluation.sensorFusionLatencyMs {
                    groundingTelemetryLatencyMs = sensorFusionLatencyMs
                }
                let preDotVerificationResolution = CompanionPreDotVerificationCoordinator.resolve(
                    guideResponse: guideResponse,
                    sensorFusionDecision: sensorFusionDecision,
                    pointWasEvaluated: pointEvaluation.point != nil,
                    guidedSetupSession: guidedSetupSession,
                    screenSignature: screenSignature,
                    screenChanged: guidedSetupScreenChanged,
                    pollIndex: guidedSetupPollIndex
                )
                guidedSetupSession = preDotVerificationResolution.guidedSetupSession
                let preDotVerificationLatencyMs = preDotVerificationResolution.latencyMs
                if let preDotRejectionReason = preDotVerificationResolution.rejectionReason {
                    pointRejectionReason = preDotRejectionReason
                }
                if preDotVerificationResolution.didFailVerification {
                    groundingTelemetryLatencyMs = CompanionGuidePipelineClock.elapsedMilliseconds(
                        since: groundingTelemetryStartedAt
                    )
                    SpiderDiagnostics.event("pre-dot verification failed")
                }
                let pointApplication = applyVisionGuidePointDecision(
                    guideResponse: guideResponse,
                    resolvedScreenState: resolvedGuideScreenState,
                    screenCaptures: screenCaptures,
                    screenChanged: guidedSetupScreenChanged,
                    pointEvaluation: pointEvaluation,
                    pointRejectionReason: pointRejectionReason,
                    telemetryMetadata: groundingTelemetryMetadata,
                    groundingTelemetryStartedAt: groundingTelemetryStartedAt,
                    latencyMs: groundingTelemetryLatencyMs,
                    screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                    visionRequestLatencyMs: visionRequestLatencyMs,
                    preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                    isAutomaticScreenRefresh: isAutomaticScreenRefresh,
                    pollIndex: guidedSetupPollIndex
                )
                groundingTelemetryLatencyMs = pointApplication.latencyMs

                recordGuideResponse(guideResponse, userTranscript: transcript)

                if let guidedSetupPollIndex {
                    handleGuidedSetupPollResult(
                        guideResponse,
                        resolvedScreenState: resolvedGuideScreenState,
                        screenSignature: screenSignature,
                        pollIndex: guidedSetupPollIndex,
                        acceptedPoint: pointApplication.acceptedPoint,
                        acceptedPointMetadata: pointApplication.acceptedPointMetadata,
                        latencyMs: groundingTelemetryLatencyMs
                    )
                }

                if GuideResponsePresentationPolicy.shouldSpeak(
                    guideResponse,
                    resolvedScreenState: resolvedGuideScreenState,
                    isAutomaticScreenRefresh: isAutomaticScreenRefresh,
                    screenChanged: guidedSetupScreenChanged
                ),
                    !guideResponse.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    willSpeakGuidance = true
                    speakGuidanceText(guideResponse.spokenText)
                }
            } catch is CancellationError {
                // User spoke again; the new request owns the next response.
            } catch CompanionVisionGuideRequestRunnerError.emptyScreenCapture {
                setVoiceState(.idle)
                speakSystemText("I need screen recording access before I can guide the next step on your screen.")
                NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            } catch let workerError as SpiderWorkerClientError {
                SpiderAnalytics.trackResponseError()
                handleWorkerClientError(workerError)
                SpiderDiagnostics.workerFailure("vision guide", statusCode: workerError.statusCode)
                speakWorkerErrorFallback(workerError)
            } catch let visionClientError as OpenAIVisionGuideClientError {
                SpiderAnalytics.trackResponseError()
                handleVisionClientError(visionClientError)
            } catch {
                SpiderAnalytics.trackResponseError()
                SpiderDiagnostics.event("vision guide response failed")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled && !willSpeakGuidance {
                setVoiceState(.idle)
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func applyVisionGuidePointDecision(
        guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        screenCaptures: [CompanionScreenCapture],
        screenChanged: Bool,
        pointEvaluation: CompanionGuidePointEvaluation,
        pointRejectionReason: SpiderGuidePointRejectionReason?,
        telemetryMetadata: GroundingTelemetryRecorder.GuideResponseMetadata,
        groundingTelemetryStartedAt: Date,
        latencyMs: Int,
        screenshotCaptureLatencyMs: Int?,
        visionRequestLatencyMs: Int?,
        preDotVerificationLatencyMs: Int?,
        isAutomaticScreenRefresh: Bool,
        pollIndex: Int?
    ) -> CompanionVisionGuidePointApplicationResult {
        var currentLatencyMs = latencyMs
        let sensorFusionDecision = pointEvaluation.sensorFusionDecision

        if let guidePoint = pointEvaluation.point,
           pointRejectionReason == nil {
            setVoiceState(.idle)
            clearGuidanceStatusBubble()
            if applyGuidePoint(guidePoint, using: screenCaptures, bubbleText: guideResponse.displayText) {
                let acceptedTelemetry = CompanionGuidePointTelemetryRecorder.recordAccepted(
                    guidePoint: guidePoint,
                    metadata: telemetryMetadata,
                    sensorFusionDecision: sensorFusionDecision,
                    groundingTelemetryStartedAt: groundingTelemetryStartedAt,
                    screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                    visionRequestLatencyMs: visionRequestLatencyMs,
                    screenChanged: screenChanged,
                    pollIndex: pollIndex
                )
                currentLatencyMs = acceptedTelemetry.timeToDotMs
                return CompanionVisionGuidePointApplicationResult(
                    acceptedPoint: guidePoint,
                    acceptedPointMetadata: acceptedTelemetry.pointMetadata,
                    latencyMs: currentLatencyMs
                )
            }

            CompanionGuidePointTelemetryRecorder.recordRejected(
                reason: .pointOutsideRegion,
                platform: currentPlatformIdForGuide(),
                guideResponse: guideResponse,
                resolvedScreenState: resolvedScreenState,
                retryPolicy: nil,
                latencyMs: currentLatencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                sensorFusionDecision: sensorFusionDecision
            )
            return CompanionVisionGuidePointApplicationResult(
                acceptedPoint: nil,
                acceptedPointMetadata: nil,
                latencyMs: currentLatencyMs
            )
        }

        if let pointRejectionReason {
            CompanionGuidePointTelemetryRecorder.recordRejected(
                reason: pointRejectionReason,
                platform: currentPlatformIdForGuide(),
                guideResponse: guideResponse,
                resolvedScreenState: resolvedScreenState,
                retryPolicy: pointRejectionReason == .outcomeFailed
                    ? guidedSetupSession?.lastGroundingOutcomeDecision?.retryPolicy
                    : nil,
                latencyMs: currentLatencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                preDotVerificationLatencyMs: preDotVerificationLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex,
                sensorFusionDecision: sensorFusionDecision
            )
        } else {
            SpiderDiagnostics.event("guide returned no point")
            CompanionGuidePointTelemetryRecorder.recordSuppressed(
                metadata: telemetryMetadata,
                latencyMs: currentLatencyMs,
                screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                visionRequestLatencyMs: visionRequestLatencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex
            )
        }

        if let pointRejectionReason,
           SpiderGuidePointSafetyPolicy.shouldHideGuidanceBubble(for: pointRejectionReason) {
            clearGuidanceStatusBubble()
        } else if GuideResponsePresentationPolicy.shouldShowStatusBubble(
            guideResponse,
            resolvedScreenState: resolvedScreenState,
            isAutomaticScreenRefresh: isAutomaticScreenRefresh,
            screenChanged: screenChanged,
            suppressRepeatedBubble: guidedSetupSession?.shouldSuppressRepeatedBubble(
                for: guideResponse,
                screenChanged: screenChanged
            ) == true
        ) {
            showGuidanceStatusBubble(guideResponse.displayText)
        }

        return CompanionVisionGuidePointApplicationResult(
            acceptedPoint: nil,
            acceptedPointMetadata: nil,
            latencyMs: currentLatencyMs
        )
    }
}
