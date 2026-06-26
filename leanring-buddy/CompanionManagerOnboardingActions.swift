//
//  CompanionManagerOnboardingActions.swift
//  leanring-buddy
//
//  Onboarding presentation and demo actions for CompanionManager. The video,
//  prompt, and demo guide flow stay separate from the normal voice guide
//  pipeline.
//

import Foundation
import SwiftUI

@MainActor
extension CompanionManager {
    /// Called by SpiderCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    func triggerOnboarding() {
        guard handleInteractionReadiness(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: accountState.canUseAI,
                allPermissionsGranted: allPermissionsGranted
            )
        ) else { return }

        NotificationCenter.default.post(name: .spiderDismissPanel, object: nil)
        hasCompletedOnboarding = true
        SpiderAnalytics.trackOnboardingStarted()
        onboardingMusicController.start()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        setOverlayVisible(true)
    }

    func replayOnboarding() {
        guard handleInteractionReadiness(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: accountState.canUseAI,
                allPermissionsGranted: allPermissionsGranted
            )
        ) else { return }

        NotificationCenter.default.post(name: .spiderDismissPanel, object: nil)
        SpiderAnalytics.trackOnboardingReplayed()
        onboardingMusicController.start()
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        setOverlayVisible(true)
    }

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by SpiderCursorView when onboarding starts.
    func setupOnboardingVideo() {
        onboardingVideoController.start(
            callbacks: CompanionOnboardingVideoController.Callbacks(
                didPreparePlayer: { [weak self] player in
                    self?.onboardingVideoPlayer = player
                    self?.showOnboardingVideo = true
                    self?.onboardingVideoOpacity = 0.0
                },
                didBecomeVisible: { [weak self] in
                    self?.onboardingVideoOpacity = 1.0
                },
                didTriggerDemo: { [weak self] in
                    SpiderAnalytics.trackOnboardingDemoTriggered()
                    self?.performOnboardingDemoInteraction()
                },
                didCompleteVideo: { [weak self] in
                    SpiderAnalytics.trackOnboardingVideoCompleted()
                    self?.onboardingVideoOpacity = 0.0
                },
                didTearDown: { [weak self] in
                    self?.showOnboardingVideo = false
                    self?.onboardingVideoPlayer = nil
                },
                didBecomeReadyForPrompt: { [weak self] in
                    self?.startOnboardingPromptStream()
                }
            )
        )
    }

    func tearDownOnboardingVideo() {
        onboardingVideoController.tearDown()
    }

    private func startOnboardingPromptStream() {
        onboardingPromptController.start(
            callbacks: CompanionOnboardingPromptController.Callbacks(
                didStart: { [weak self] in
                    self?.onboardingPromptText = ""
                    self?.showOnboardingPrompt = true
                    self?.onboardingPromptOpacity = 0.0

                    withAnimation(
                        .easeIn(duration: CompanionOnboardingPromptPolicy.fadeInDurationSeconds)
                    ) {
                        self?.onboardingPromptOpacity = 1.0
                    }
                },
                didAppendCharacter: { [weak self] character in
                    self?.onboardingPromptText.append(character)
                },
                shouldAutoDismiss: { [weak self] in
                    self?.showOnboardingPrompt ?? false
                },
                didBeginDismiss: { [weak self] in
                    withAnimation(
                        .easeOut(duration: CompanionOnboardingPromptPolicy.fadeOutDurationSeconds)
                    ) {
                        self?.onboardingPromptOpacity = 0.0
                    }
                },
                didFinishDismiss: { [weak self] in
                    self?.showOnboardingPrompt = false
                    self?.onboardingPromptText = ""
                }
            )
        )
    }

    /// Captures a screenshot and asks Spider to point at a useful next action.
    /// Used during onboarding to demo the screen-first guidance loop.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }
        guard handleInteractionReadiness(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: accountState.canUseAI,
                allPermissionsGranted: allPermissionsGranted
            )
        ) else { return }

        Task {
            do {
                try await validateAIEntitlementBeforeScreenCapture()
                let demoGuideResult = try await CompanionOnboardingDemoGuideRunner.run(
                    guideClient: spiderVisionGuideClient,
                    adMissionSnapshot: adMission,
                    platformContext: currentPlatformContextForGuide(),
                    platformId: currentPlatformIdForGuide(),
                    appLanguage: SpiderUserPreferences.appLanguage
                )
                let guideResponse = demoGuideResult.guideResponse
                let cursorScreenCapture = demoGuideResult.cursorScreenCapture
                let resolvedGuideScreenState = demoGuideResult.resolvedScreenState
                let groundingTelemetryMetadata = demoGuideResult.telemetryMetadata
                let pointEvaluation = demoGuideResult.pointEvaluation
                let pointRejectionReason = pointEvaluation.rejectionReason
                let sensorFusionDecision = pointEvaluation.sensorFusionDecision
                var groundingTelemetryLatencyMs = demoGuideResult.groundingTelemetryLatencyMs
                let groundingTelemetryStartedAt = demoGuideResult.groundingTelemetryStartedAt
                let screenshotCaptureLatencyMs = demoGuideResult.screenshotCaptureLatencyMs
                let visionRequestLatencyMs = demoGuideResult.visionRequestLatencyMs

                guard let guidePoint = pointEvaluation.point,
                      pointRejectionReason == nil else {
                    if let pointRejectionReason {
                        CompanionGuidePointTelemetryRecorder.recordRejected(
                            reason: pointRejectionReason,
                            platform: currentPlatformIdForGuide(),
                            guideResponse: guideResponse,
                            resolvedScreenState: resolvedGuideScreenState,
                            retryPolicy: nil,
                            latencyMs: groundingTelemetryLatencyMs,
                            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                            visionRequestLatencyMs: visionRequestLatencyMs,
                            screenChanged: true,
                            pollIndex: nil,
                            sensorFusionDecision: sensorFusionDecision
                        )
                        if pointRejectionReason == .sensorFusionContradicted {
                            clearGuidanceStatusBubble()
                        }
                    } else {
                        SpiderDiagnostics.event("onboarding demo returned no safe point")
                        CompanionGuidePointTelemetryRecorder.recordSuppressed(
                            metadata: groundingTelemetryMetadata,
                            latencyMs: groundingTelemetryLatencyMs,
                            screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                            visionRequestLatencyMs: visionRequestLatencyMs,
                            screenChanged: true,
                            pollIndex: nil
                        )
                    }
                    return
                }

                if applyGuidePoint(guidePoint, using: [cursorScreenCapture], bubbleText: guideResponse.displayText) {
                    let acceptedTelemetry = CompanionGuidePointTelemetryRecorder.recordAccepted(
                        guidePoint: guidePoint,
                        metadata: groundingTelemetryMetadata,
                        sensorFusionDecision: sensorFusionDecision,
                        groundingTelemetryStartedAt: groundingTelemetryStartedAt,
                        screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                        visionRequestLatencyMs: visionRequestLatencyMs,
                        screenChanged: true,
                        pollIndex: nil
                    )
                    groundingTelemetryLatencyMs = acceptedTelemetry.timeToDotMs
                    SpiderDiagnostics.event("onboarding demo point accepted")
                } else {
                    CompanionGuidePointTelemetryRecorder.recordRejected(
                        reason: .pointOutsideRegion,
                        platform: currentPlatformIdForGuide(),
                        guideResponse: guideResponse,
                        resolvedScreenState: resolvedGuideScreenState,
                        retryPolicy: nil,
                        latencyMs: groundingTelemetryLatencyMs,
                        screenshotCaptureLatencyMs: screenshotCaptureLatencyMs,
                        visionRequestLatencyMs: visionRequestLatencyMs,
                        screenChanged: true,
                        pollIndex: nil,
                        sensorFusionDecision: sensorFusionDecision
                    )
                }
            } catch let workerError as SpiderWorkerClientError {
                handleWorkerClientError(workerError)
                SpiderDiagnostics.workerFailure("onboarding demo", statusCode: workerError.statusCode)
            } catch let visionClientError as OpenAIVisionGuideClientError {
                handleVisionClientError(visionClientError)
            } catch CompanionOnboardingDemoGuideRunnerError.emptyScreenCapture {
                speakSystemText("I need screen recording access before I can point at anything useful.")
                NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            } catch CompanionOnboardingDemoGuideRunnerError.cursorScreenUnavailable {
                SpiderDiagnostics.event("onboarding demo cursor screen unavailable")
            } catch {
                SpiderDiagnostics.event("onboarding demo failed")
            }
        }
    }
}
