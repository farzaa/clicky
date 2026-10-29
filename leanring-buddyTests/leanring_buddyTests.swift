//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import AppKit
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

    @Test func defaultTextInputShortcutUsesOptionCommandK() async throws {
        let shortcut = ClickyKeyboardShortcut.defaultTextInputShortcut

        #expect(shortcut.keyCode == 40)
        #expect(shortcut.modifierFlags.contains(.option))
        #expect(shortcut.modifierFlags.contains(.command))
        #expect(shortcut.displayText == "⌥⌘K")
        #expect(shortcut.validationErrorMessage == nil)
    }

    @Test func textInputShortcutRejectsVoiceShortcutConflict() async throws {
        let shortcut = ClickyKeyboardShortcut(
            keyCode: 49,
            modifierFlags: [.control, .option],
            keyDisplayText: "Space"
        )

        #expect(shortcut.validationErrorMessage == "Control+Option is reserved for voice.")
    }

}
