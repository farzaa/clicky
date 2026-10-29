//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func recentAppleSpeechDenialRemainsDeniedDuringPermissionCooldown() {
        let shouldTreatPermissionAsGranted = BuddyDictationManager.shouldTreatRecentPermissionRequestAsGranted(
            microphonePermissionIsUsable: true,
            speechRecognitionPermissionIsUsable: false,
            requiresSpeechRecognitionPermission: true
        )

        #expect(!shouldTreatPermissionAsGranted)
    }

    @Test func providersWithoutSpeechPermissionIgnoreSpeechDenialDuringPermissionCooldown() {
        let shouldTreatPermissionAsGranted = BuddyDictationManager.shouldTreatRecentPermissionRequestAsGranted(
            microphonePermissionIsUsable: true,
            speechRecognitionPermissionIsUsable: false,
            requiresSpeechRecognitionPermission: false
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func recentMicrophoneDenialRemainsDeniedForEveryProvider() {
        let shouldTreatPermissionAsGranted = BuddyDictationManager.shouldTreatRecentPermissionRequestAsGranted(
            microphonePermissionIsUsable: false,
            speechRecognitionPermissionIsUsable: true,
            requiresSpeechRecognitionPermission: false
        )

        #expect(!shouldTreatPermissionAsGranted)
    }

    @Test func recentAppleSpeechPermissionsRemainGrantedWhenBothAreUsable() {
        let shouldTreatPermissionAsGranted = BuddyDictationManager.shouldTreatRecentPermissionRequestAsGranted(
            microphonePermissionIsUsable: true,
            speechRecognitionPermissionIsUsable: true,
            requiresSpeechRecognitionPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

}
