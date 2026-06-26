//
//  CompanionManagerPresentationActions.swift
//  leanring-buddy
//
//  Presentation, speech, and guide-point application actions for
//  CompanionManager. The manager still owns state; this extension keeps UI
//  side effects away from the core request pipeline.
//

import Foundation

@MainActor
extension CompanionManager {
    func handleVisionClientError(_ error: OpenAIVisionGuideClientError) {
        for action in CompanionVisionGuideErrorPresentationPolicy.presentation(for: error).actions {
            switch action {
            case let .markLoggedOut(message, clearStoredToken):
                markLoggedOut(message: message, clearStoredToken: clearStoredToken)
            case .showPanel:
                NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            case let .recordDiagnosticEvent(diagnosticEvent):
                SpiderDiagnostics.event(diagnosticEvent.message)
            case let .speakSystemText(text):
                speakSystemText(text)
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementPointLabel = nil
        detectedElementMissionAlignment = nil
    }

    func clearGuidanceStatusBubble() {
        guidanceStatusBubbleController.clear(callbacks: guidanceStatusBubbleCallbacks())
    }

    func showGuidanceStatusBubble(_ text: String) {
        guidanceStatusBubbleController.show(text, callbacks: guidanceStatusBubbleCallbacks())
    }

    func guidanceStatusBubbleCallbacks() -> CompanionGuidanceStatusBubbleController.Callbacks {
        CompanionGuidanceStatusBubbleController.Callbacks(
            didRequestCursorVisible: { [weak self] in
                self?.showSpiderCursorForGuidedSetupIfPossible()
            },
            didShow: { [weak self] text in
                self?.guidanceStatusText = text
                self?.guidanceStatusOpacity = 1
            },
            didHide: { [weak self] in
                self?.guidanceStatusOpacity = 0
                self?.guidanceStatusText = ""
            }
        )
    }

    @discardableResult
    func applyGuidePoint(
        _ guidePoint: SpiderGuidePoint,
        using screenCaptures: [CompanionScreenCapture],
        bubbleText: String
    ) -> Bool {
        switch CompanionGuidePointOverlayPresenter.application(
            for: guidePoint,
            screenCaptures: screenCaptures,
            bubbleText: bubbleText
        ) {
        case .accepted(let state):
            detectedElementBubbleText = state.bubbleText
            detectedElementPointLabel = state.pointLabel
            detectedElementMissionAlignment = state.missionAlignment
            detectedElementScreenLocation = state.screenLocation
            detectedElementDisplayFrame = state.displayFrame
            detectedElementTargetRevision = state.targetRevision
            SpiderAnalytics.trackElementPointed()
            SpiderDiagnostics.event("guide point accepted")
            return true
        case .rejected(let rejection):
            SpiderDiagnostics.event(CompanionGuidePointOverlayPresenter.diagnosticEvent(for: rejection))
            return false
        }
    }

    func ensureProductFeatureAvailable(_ feature: SpiderProductFeature) -> Bool {
        let descriptor = SpiderProductFeatures.descriptor(for: feature)

        guard descriptor.isAvailable else {
            SpiderAnalytics.trackLockedFeatureRequested(feature)
            showGuidanceStatusBubble(descriptor.lockedStatusText)
            speakSystemText(descriptor.lockedVoiceText)
            return false
        }

        return true
    }

    func speakSystemText(_ text: String) {
        speechPlaybackController.speakSystemText(text, callbacks: speechPlaybackCallbacks())
    }

    func speakGuidanceText(_ text: String) {
        speechPlaybackController.speakGuidanceText(text, callbacks: speechPlaybackCallbacks())
    }

    func speechPlaybackCallbacks() -> CompanionSpeechPlaybackController.Callbacks {
        CompanionSpeechPlaybackController.Callbacks(
            setVoiceState: { [weak self] state in
                self?.setVoiceState(state)
            },
            handleWorkerError: { [weak self] error in
                self?.handleWorkerClientError(error)
            },
            scheduleTransientHideIfNeeded: { [weak self] in
                self?.scheduleTransientHideIfNeeded()
            }
        )
    }

    func speakAccountBlockedMessage() {
        guard let message = CompanionSpeechPolicy.accountBlockedMessage(for: accountState) else {
            return
        }

        speakSystemText(message)
    }

    func speakPermissionsBlockedMessage() {
        speakSystemText(
            CompanionSpeechPolicy.permissionsBlockedMessage(
                hasAccessibilityPermission: hasAccessibilityPermission,
                hasMicrophonePermission: hasMicrophonePermission,
                hasScreenRecordingPermission: hasScreenRecordingPermission,
                hasScreenContentPermission: hasScreenContentPermission
            )
        )
    }

    func speakScreenGuidanceBlockedMessage() {
        speakSystemText(CompanionSpeechPolicy.screenGuidanceBlockedMessage)
    }

    func scheduleTransientHideIfNeeded() {
        transientOverlayHideController.scheduleIfNeeded(
            isSpiderCursorEnabled: isSpiderCursorEnabled,
            isOverlayVisible: isOverlayVisible,
            callbacks: CompanionTransientOverlayHideController.Callbacks(
                isSystemSpeechSpeaking: { [weak self] in
                    self?.speechPlaybackController.isSystemSpeechSpeaking == true
                },
                isPointAnimationActive: { [weak self] in
                    self?.detectedElementScreenLocation != nil
                },
                hideOverlay: { [weak self] in
                    self?.overlayWindowManager.fadeOutAndHideOverlay()
                    self?.setOverlayVisible(false)
                }
            )
        )
    }

    func speakCreditsErrorFallback() {
        speakSystemText(CompanionSpeechPolicy.guidanceUnavailableMessage)
    }

    func speakWorkerErrorFallback(_ error: SpiderWorkerClientError) {
        speakSystemText(CompanionSpeechPolicy.workerErrorFallbackMessage(for: error))
    }

    func handleInteractionReadiness(
        _ decision: CompanionInteractionReadinessPolicy.Decision
    ) -> Bool {
        switch decision {
        case .ready:
            return true
        case .accountBlocked:
            speakAccountBlockedMessage()
        case .permissionsBlocked:
            speakPermissionsBlockedMessage()
        case .screenGuidanceBlocked:
            speakScreenGuidanceBlockedMessage()
        }

        NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
        return false
    }
}
