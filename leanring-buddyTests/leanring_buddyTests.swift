//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
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

    @Test func standaloneControlTapCompletesOnlyWhenControlIsPressedAndReleasedAlone() throws {
        var tracker = StandaloneControlKeyTapTracker()

        // Pressing Control alone: not yet complete
        let controlDownCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )
        #expect(!controlDownCompleted)

        // Releasing Control back to no modifiers: completed
        let controlUpCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: 0
        )
        #expect(controlUpCompleted)
    }

    @Test func modifierCombosLikeControlOptionDoNotTriggerStandaloneControlTap() throws {
        var tracker = StandaloneControlKeyTapTracker()

        // Press Control
        _ = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )

        // Press Option (now Control + Option for push-to-talk)
        let comboFlags = NSEvent.ModifierFlags([.control, .option])
        let comboDownCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(comboFlags.rawValue)
        )
        #expect(!comboDownCompleted)

        // Release Option first (leaving Control)
        let backToControlCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )
        #expect(!backToControlCompleted)

        // Release Control
        let finalReleaseCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: 0
        )
        #expect(!finalReleaseCompleted)
    }

    @Test func normalKeyTypingCancelsStandaloneControlTap() throws {
        var tracker = StandaloneControlKeyTapTracker()

        // Press Control
        _ = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )

        // Press a normal key (e.g. while typing a shortcut like Ctrl+C)
        let keyDownCompleted = tracker.didCompleteStandaloneControlTap(
            for: .keyDown,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )
        #expect(!keyDownCompleted)

        // Release Control
        let releaseCompleted = tracker.didCompleteStandaloneControlTap(
            for: .flagsChanged,
            modifierFlagsRawValue: 0
        )
        #expect(!releaseCompleted)
    }

}
