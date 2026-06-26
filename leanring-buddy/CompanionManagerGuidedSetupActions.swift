//
//  CompanionManagerGuidedSetupActions.swift
//  leanring-buddy
//
//  Guided Setup orchestration for CompanionManager. The session state remains
//  in GuidedSetupSession; this file owns launch, polling, and poll result flow.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {
    func openConfiguredAdPlatformAndStartGuidedSetup() {
        guard ensureProductFeatureAvailable(.firstStepGuidedSetup) else { return }

        clearGuidanceStatusBubble()
        saveAdMissionIfChanged(AdMissionLifecyclePolicy.guidedSetupStarted(
            adMission,
            platformDisplayName: configuredAdPlatformDisplayName
        ))

        if let url = URL(string: configuredAdPlatformURLString()) {
            NSWorkspace.shared.open(url)
        }
        showSpiderCursorForGuidedSetupIfPossible()
        scheduleInitialGuidedSetupStep()
        SpiderAnalytics.trackGuidedSetupStarted()
        NotificationCenter.default.post(name: .spiderDismissPanel, object: nil)
    }

    func requestGuidedSetupStepFromCurrentScreen() {
        guard ensureProductFeatureAvailable(.firstStepGuidedSetup) else { return }

        sendTranscriptToSpiderGuideWithScreenshot(
            transcript: GuidedSetupPromptComposer.currentScreenTranscript,
            platformContext: currentPlatformContextForGuide()
        )
    }

    func scheduleInitialGuidedSetupStep() {
        guidedSetupPollScheduler.cancelPendingPoll()
        guidedSetupSession = GuidedSetupSession(platformId: currentPlatformIdForGuide())
        scheduleNextGuidedSetupPoll(after: GuidedSetupPollingPolicy.initialPollDelayNanoseconds)
    }

    func scheduleNextGuidedSetupPoll(after delayNanoseconds: UInt64) {
        guidedSetupPollScheduler.schedule(after: delayNanoseconds) { [weak self] in
            self?.runScheduledGuidedSetupStep()
        }
    }

    func runScheduledGuidedSetupStep() {
        guard var guidedSetupSession else {
            guidedSetupPollScheduler.cancelPendingPoll()
            return
        }

        if isVisionGuideRequestInFlight {
            scheduleNextGuidedSetupPoll(after: GuidedSetupPollingPolicy.loadingPollDelayNanoseconds)
            return
        }

        guard let pollIndex = guidedSetupSession.nextPollIndex(
            maximumAutomaticPolls: GuidedSetupPollingPolicy.maximumAutomaticPolls
        ) else {
            guidedSetupPollScheduler.cancelPendingPoll()
            self.guidedSetupSession = nil
            return
        }

        self.guidedSetupSession = guidedSetupSession

        sendTranscriptToSpiderGuideWithScreenshot(
            transcript: GuidedSetupPromptComposer.pollTranscript(pollIndex: pollIndex),
            platformContext: currentPlatformContextForGuide(),
            cancelsGuidedSetupPolling: false,
            cancelsCurrentResponse: false,
            isAutomaticScreenRefresh: true,
            guidedSetupPollIndex: pollIndex
        )
    }

    func handleGuidedSetupPollResult(
        _ guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        screenSignature: String,
        pollIndex: Int,
        acceptedPoint: SpiderGuidePoint?,
        acceptedPointMetadata: GroundingTelemetryRecorder.PointAcceptanceMetadata?,
        latencyMs: Int
    ) {
        guard var guidedSetupSession else { return }
        let screenChanged = guidedSetupSession.screenChanged(for: screenSignature)
        let pendingPointOutcome = guidedSetupSession.pendingPointOutcome
        if let outcomeDecision = guidedSetupSession.evaluatePendingPointOutcome(
            response: guideResponse,
            resolvedScreenState: resolvedScreenState,
            screenChanged: screenChanged
        ) {
            let outcomeStatus = outcomeDecision.outcomeStatus
            SpiderAnalytics.trackGuidePointOutcome(status: outcomeStatus)
            let groundingTelemetryMetadata = GroundingTelemetryRecorder.guideResponseMetadata(
                platform: currentPlatformIdForGuide(),
                guideResponse: guideResponse,
                resolvedScreenState: resolvedScreenState
            )
            GroundingTelemetryRecorder.recordOutcomeEvaluated(
                metadata: groundingTelemetryMetadata,
                targetElementIdHash: pendingPointOutcome?.targetElementIdHash,
                expectedOutcome: pendingPointOutcome?.expectedOutcome,
                outcomeStatus: outcomeStatus,
                retryPolicy: outcomeDecision.retryPolicy,
                latencyMs: latencyMs,
                screenChanged: screenChanged,
                pollIndex: pollIndex
            )
            SpiderDiagnostics.event("guide point outcome evaluated")
        }
        if resolvedScreenState == .loading,
           guidedSetupSession.shouldForceLoadingReclassification {
            SpiderAnalytics.trackGuideLoadingReclassification()
        }
        if resolvedScreenState == .unknown {
            SpiderAnalytics.trackGuideUnknownScreen()
        }

        guidedSetupSession.record(
            response: guideResponse,
            screenSignature: screenSignature,
            resolvedScreenState: resolvedScreenState,
            screenChanged: screenChanged,
            acceptedPoint: acceptedPoint,
            acceptedPointTargetElementIdHash: acceptedPointMetadata?.targetElementIdHash,
            acceptedPointTargetFingerprint: acceptedPointMetadata?.targetFingerprint,
            pollIndex: pollIndex
        )
        self.guidedSetupSession = guidedSetupSession

        switch GuidedSetupPollingPolicy.continuationDecision(
            afterPollIndex: pollIndex,
            for: guidedSetupSession,
            screenState: resolvedScreenState,
            shouldContinuePolling: guideResponse.shouldContinuePolling,
            suggestedPollAfterMs: guideResponse.pollAfterMs
        ) {
        case .finish:
            guidedSetupPollScheduler.cancelPendingPoll()
            self.guidedSetupSession = nil
        case .continueAfter(let delayNanoseconds):
            scheduleNextGuidedSetupPoll(after: delayNanoseconds)
        }
    }
}
