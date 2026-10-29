//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
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

    @MainActor
    @Test func currentTranscriptionSessionCallbackIsAccepted() {
        let currentSessionIdentifier = UUID()

        let shouldAcceptCallback = BuddyDictationManager.shouldAcceptTranscriptionCallback(
            callbackSessionIdentifier: currentSessionIdentifier,
            activeSessionIdentifier: currentSessionIdentifier
        )

        #expect(shouldAcceptCallback)
    }

    @MainActor
    @Test func cancelledTranscriptionSessionCallbackIsRejected() {
        let shouldAcceptCallback = BuddyDictationManager.shouldAcceptTranscriptionCallback(
            callbackSessionIdentifier: UUID(),
            activeSessionIdentifier: UUID()
        )

        #expect(!shouldAcceptCallback)
    }

}
