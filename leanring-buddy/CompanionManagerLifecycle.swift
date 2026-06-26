//
//  CompanionManagerLifecycle.swift
//  leanring-buddy
//
//  App lifecycle, voice-state bindings, and global shortcut handling for
//  CompanionManager.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
extension CompanionManager {
    func start() {
        CompanionAccountLocalStateStore.clearPendingEmail()
        refreshAllPermissions()
        refreshLoginStatus()
        CompanionPermissionTelemetryRecorder.recordDiagnosticFlags(for: companionPermissionState)
        SpiderDiagnostics.flag("onboarded", hasCompletedOnboarding)
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        _ = spiderVisionGuideClient

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor; the panel
        // will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isSpiderCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            setOverlayVisible(true)
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientOverlayHideController.cancelPendingHide()
        guidedSetupPollScheduler.cancelPendingPoll()
        clearGuidanceStatusBubble()

        currentResponseTask?.cancel()
        speechPlaybackController.cancelGuidanceSpeech()
        currentResponseTask = nil
        guidedSetupSession = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        clearPermissionPollingTimer()
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.setCurrentAudioPowerLevel(powerLevel)
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding; the AI response pipeline manages
                // that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.setVoiceState(.processing)
                } else if isRecording {
                    self.setVoiceState(.listening)
                } else if isPreparing {
                    self.setVoiceState(.processing)
                } else {
                    self.setVoiceState(.idle)
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }
            keyboardShortcutPressedAt = Date()
            keyboardShortcutDidStartDictation = false

            guard handleInteractionReadiness(
                CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                    accountCanUseAI: accountState.canUseAI,
                    allPermissionsGranted: allPermissionsGranted
                )
            ) else { return }

            transientOverlayHideController.cancelPendingHide()

            if !isSpiderCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                setOverlayVisible(true)
            }

            NotificationCenter.default.post(name: .spiderDismissPanel, object: nil)

            currentResponseTask?.cancel()
            speechPlaybackController.stopAllSpeech()
            clearDetectedElementLocation()
            dismissOnboardingPromptIfVisible()

            SpiderAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                try? await Task.sleep(
                    nanoseconds: CompanionKeyboardShortcutPolicy.holdToTalkDelayNanoseconds
                )
                guard !Task.isCancelled else { return }
                keyboardShortcutDidStartDictation = true
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI).
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.setLastTranscript(finalTranscript)
                        SpiderDiagnostics.count("transcript_character_count", finalTranscript.count)
                        SpiderAnalytics.trackUserMessageSent(transcriptCharacterCount: finalTranscript.count)
                        self?.sendTranscriptToSpiderGuideWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            let shouldSummonCompanion = shouldTreatKeyboardShortcutReleaseAsSummon()
            keyboardShortcutPressedAt = nil
            keyboardShortcutDidStartDictation = false
            SpiderAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            if shouldSummonCompanion {
                summonCompanionFromKeyboardShortcut()
            }
        case .none:
            break
        }
    }

    private func dismissOnboardingPromptIfVisible() {
        guard showOnboardingPrompt else { return }

        onboardingPromptController.cancel()
        withAnimation(.easeOut(duration: CompanionOnboardingPromptPolicy.fadeOutDurationSeconds)) {
            onboardingPromptOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CompanionOnboardingPromptPolicy.teardownDelaySeconds
        ) {
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    private func shouldTreatKeyboardShortcutReleaseAsSummon() -> Bool {
        CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(
            CompanionKeyboardShortcutPolicy.ReleaseState(
                pressedAt: keyboardShortcutPressedAt,
                now: Date(),
                didStartDictation: keyboardShortcutDidStartDictation,
                isSessionActiveOrFinalizing: buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing,
                isRecording: buddyDictationManager.isRecordingFromKeyboardShortcut,
                isPreparingToRecord: buddyDictationManager.isPreparingToRecord
            )
        )
    }

    private func summonCompanionFromKeyboardShortcut() {
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        keyboardShortcutPressedAt = nil
        keyboardShortcutDidStartDictation = false

        if buddyDictationManager.isRecordingFromKeyboardShortcut
            || buddyDictationManager.isKeyboardShortcutSessionActiveOrFinalizing {
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        }

        refreshAllPermissions()

        if accountState.canUseAI && hasScreenGuidancePermissions {
            showSpiderCursorForGuidedSetupIfPossible()
            return
        }

        NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
    }
}
