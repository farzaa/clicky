//
//  CompanionTransientOverlayHideControllerTests.swift
//  leanring-buddyTests
//
//  Tests delayed transient overlay hiding without touching real windows.
//

import Testing
@testable import Spider

@MainActor
struct CompanionTransientOverlayHideControllerTests {
    @Test func scheduleRequiresDisabledCursorAndVisibleOverlay() {
        let controller = CompanionTransientOverlayHideController(timing: .immediateForTesting)
        var hideCount = 0
        let callbacks = CompanionTransientOverlayHideController.Callbacks(
            isSystemSpeechSpeaking: { false },
            isPointAnimationActive: { false },
            hideOverlay: { hideCount += 1 }
        )

        #expect(controller.scheduleIfNeeded(
            isSpiderCursorEnabled: true,
            isOverlayVisible: true,
            callbacks: callbacks
        ) == nil)
        #expect(controller.scheduleIfNeeded(
            isSpiderCursorEnabled: false,
            isOverlayVisible: false,
            callbacks: callbacks
        ) == nil)
        #expect(hideCount == 0)
    }

    @Test func scheduledHideRunsAfterSpeechAndPointAnimationAreIdle() async {
        let controller = CompanionTransientOverlayHideController(timing: .immediateForTesting)
        var isSpeechSpeaking = true
        var isPointAnimationActive = true
        var hideCount = 0

        let task = controller.scheduleIfNeeded(
            isSpiderCursorEnabled: false,
            isOverlayVisible: true,
            callbacks: CompanionTransientOverlayHideController.Callbacks(
                isSystemSpeechSpeaking: {
                    defer { isSpeechSpeaking = false }
                    return isSpeechSpeaking
                },
                isPointAnimationActive: {
                    defer { isPointAnimationActive = false }
                    return isPointAnimationActive
                },
                hideOverlay: { hideCount += 1 }
            )
        )
        await task?.value

        #expect(hideCount == 1)
    }

    @Test func cancelPendingHidePreventsOverlayHide() async {
        let controller = CompanionTransientOverlayHideController(timing: .immediateForTesting)
        var hideCount = 0
        let task = controller.scheduleIfNeeded(
            isSpiderCursorEnabled: false,
            isOverlayVisible: true,
            callbacks: CompanionTransientOverlayHideController.Callbacks(
                isSystemSpeechSpeaking: { false },
                isPointAnimationActive: { false },
                hideOverlay: { hideCount += 1 }
            )
        )

        controller.cancelPendingHide()
        await task?.value

        #expect(hideCount == 0)
    }
}

private extension CompanionTransientOverlayHideController.Timing {
    static let immediateForTesting = CompanionTransientOverlayHideController.Timing(
        pollIntervalNanoseconds: 0,
        finalDelayNanoseconds: 0
    )
}
