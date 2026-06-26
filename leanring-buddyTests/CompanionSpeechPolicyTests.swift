//
//  CompanionSpeechPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for bounded companion speech and sanitized Worker fallbacks.
//

import Foundation
import Testing
@testable import Spider

private enum CompanionSpeechPlaybackTestError: Error {
    case failed
}

@MainActor
private final class FakeRealtimeSpeechPlayer: CompanionRealtimeSpeechPlaying {
    var spokenTexts: [String] = []
    var stopCount = 0
    var errorToThrow: Error?

    func speak(_ text: String) async throws {
        if let errorToThrow {
            throw errorToThrow
        }
        spokenTexts.append(text)
    }

    func stopActiveSpeech() {
        stopCount += 1
    }
}

@MainActor
private final class FakeSystemSpeechPlayer: CompanionSystemSpeechPlaying {
    var isSpeaking = false
    var spokenTexts: [String] = []
    var stopCount = 0

    func stop() {
        stopCount += 1
        isSpeaking = false
    }

    func speak(_ text: String) {
        spokenTexts.append(text)
    }
}

struct CompanionSpeechPolicyTests {
    @Test func speechTextIsBoundedForSystemAndGuidancePlayback() {
        let longText = """
        First sentence is intentionally long enough to exceed the system word budget by repeating safe public words only. Second sentence should not matter. Third sentence should never be included.
        """

        let systemText = CompanionSpeechPolicy.systemText(longText)
        let guidanceText = CompanionSpeechPolicy.guidanceText(longText)

        #expect(systemText.split(whereSeparator: { $0.isWhitespace }).count <= 18)
        #expect(systemText.count <= 140)
        #expect(guidanceText.split(whereSeparator: { $0.isWhitespace }).count <= 22)
        #expect(guidanceText.count <= 220)
        #expect(!systemText.contains("\n"))
        #expect(!guidanceText.contains("\n"))
    }

    @Test func accountBlockedMessagesStayStatusBased() {
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .loggedOut) == "Sign in first.")
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .checking) == "Checking account. Try again.")
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .paymentRequired) == "Upgrade required.")
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .error("network")) == "Sign in again.")
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .active) == nil)
        #expect(CompanionSpeechPolicy.accountBlockedMessage(for: .trial) == nil)
    }

    @Test func permissionBlockedMessageKeepsExistingPriority() {
        #expect(
            CompanionSpeechPolicy.permissionsBlockedMessage(
                hasAccessibilityPermission: false,
                hasMicrophonePermission: false,
                hasScreenRecordingPermission: false,
                hasScreenContentPermission: false
            ) == "Grant Accessibility first."
        )
        #expect(
            CompanionSpeechPolicy.permissionsBlockedMessage(
                hasAccessibilityPermission: true,
                hasMicrophonePermission: false,
                hasScreenRecordingPermission: false,
                hasScreenContentPermission: false
            ) == "Grant Microphone first."
        )
        #expect(
            CompanionSpeechPolicy.permissionsBlockedMessage(
                hasAccessibilityPermission: true,
                hasMicrophonePermission: true,
                hasScreenRecordingPermission: false,
                hasScreenContentPermission: true
            ) == "Grant screen permissions first."
        )
        #expect(
            CompanionSpeechPolicy.permissionsBlockedMessage(
                hasAccessibilityPermission: true,
                hasMicrophonePermission: true,
                hasScreenRecordingPermission: true,
                hasScreenContentPermission: true
            ) == "Finish permissions in Spider."
        )
    }

    @Test func workerFallbackMessagesUseSanitizedStatusOnly() {
        #expect(
            CompanionSpeechPolicy.workerErrorFallbackMessage(
                for: SpiderWorkerClientError(statusCode: 401, operation: "vision guide")
            ) == "Your Spider session expired. Sign in again before I can look at your screen."
        )
        #expect(
            CompanionSpeechPolicy.workerErrorFallbackMessage(
                for: SpiderWorkerClientError(statusCode: 403, operation: "vision guide")
            ) == "Your Spider account needs an active subscription before I can use AI guidance."
        )
        #expect(
            CompanionSpeechPolicy.workerErrorFallbackMessage(
                for: SpiderWorkerClientError(statusCode: 429, operation: "vision guide")
            ) == "You hit your Spider usage limit for now. Try again later."
        )
        #expect(
            CompanionSpeechPolicy.workerErrorFallbackMessage(
                for: SpiderWorkerClientError(statusCode: 413, operation: "vision guide")
            ) == "That screenshot is too large to send safely. Try again with fewer displays connected."
        )
        #expect(
            CompanionSpeechPolicy.workerErrorFallbackMessage(
                for: SpiderWorkerClientError(statusCode: 500, operation: "private payload must not leak")
            ) == CompanionSpeechPolicy.guidanceUnavailableMessage
        )
    }

    @MainActor
    @Test func speechPlaybackControllerUsesSystemPolicyAndStateCallback() {
        let realtimeSpeechPlayer = FakeRealtimeSpeechPlayer()
        let systemSpeechPlayer = FakeSystemSpeechPlayer()
        let controller = CompanionSpeechPlaybackController(
            realtimeVoiceClient: realtimeSpeechPlayer,
            systemSpeechPlayer: systemSpeechPlayer
        )
        var voiceStates: [CompanionVoiceState] = []

        controller.speakSystemText(
            "First sentence is intentionally long enough to need system speech truncation. Second sentence is ignored.",
            callbacks: CompanionSpeechPlaybackController.Callbacks(
                setVoiceState: { voiceStates.append($0) },
                handleWorkerError: { _ in },
                scheduleTransientHideIfNeeded: {}
            )
        )

        #expect(realtimeSpeechPlayer.spokenTexts.isEmpty)
        #expect(systemSpeechPlayer.spokenTexts.count == 1)
        #expect(systemSpeechPlayer.spokenTexts.first?.split(whereSeparator: { $0.isWhitespace }).count ?? 0 <= 18)
        #expect(voiceStates == [.responding])
    }

    @MainActor
    @Test func speechPlaybackControllerUsesRealtimeForGuidanceAndSchedulesHide() async {
        let realtimeSpeechPlayer = FakeRealtimeSpeechPlayer()
        let systemSpeechPlayer = FakeSystemSpeechPlayer()
        let controller = CompanionSpeechPlaybackController(
            realtimeVoiceClient: realtimeSpeechPlayer,
            systemSpeechPlayer: systemSpeechPlayer
        )
        var voiceStates: [CompanionVoiceState] = []
        var scheduledHideCount = 0

        let task = controller.speakGuidanceText(
            "Read the screen and explain the next safe step.",
            callbacks: CompanionSpeechPlaybackController.Callbacks(
                setVoiceState: { voiceStates.append($0) },
                handleWorkerError: { _ in },
                scheduleTransientHideIfNeeded: { scheduledHideCount += 1 }
            )
        )
        await task?.value

        #expect(realtimeSpeechPlayer.stopCount == 1)
        #expect(realtimeSpeechPlayer.spokenTexts == ["Read the screen and explain the next safe step."])
        #expect(systemSpeechPlayer.spokenTexts.isEmpty)
        #expect(voiceStates == [.responding, .idle])
        #expect(scheduledHideCount == 1)
    }

    @MainActor
    @Test func speechPlaybackControllerFallsBackToSystemSpeechOnWorkerError() async {
        let realtimeSpeechPlayer = FakeRealtimeSpeechPlayer()
        realtimeSpeechPlayer.errorToThrow = SpiderWorkerClientError(
            statusCode: 429,
            operation: "private payload must not leak"
        )
        let systemSpeechPlayer = FakeSystemSpeechPlayer()
        let controller = CompanionSpeechPlaybackController(
            realtimeVoiceClient: realtimeSpeechPlayer,
            systemSpeechPlayer: systemSpeechPlayer
        )
        var workerStatusCodes: [Int?] = []
        var voiceStates: [CompanionVoiceState] = []
        var scheduledHideCount = 0

        let task = controller.speakGuidanceText(
            "This guidance should fall back safely.",
            callbacks: CompanionSpeechPlaybackController.Callbacks(
                setVoiceState: { voiceStates.append($0) },
                handleWorkerError: { workerStatusCodes.append($0.statusCode) },
                scheduleTransientHideIfNeeded: { scheduledHideCount += 1 }
            )
        )
        await task?.value

        #expect(realtimeSpeechPlayer.spokenTexts.isEmpty)
        #expect(workerStatusCodes == [429])
        #expect(systemSpeechPlayer.spokenTexts == ["This guidance should fall back safely."])
        #expect(voiceStates == [.responding, .responding, .idle])
        #expect(scheduledHideCount == 1)
    }

    @MainActor
    @Test func speechPlaybackControllerKeepsCancelAndStopScopesSeparate() {
        let realtimeSpeechPlayer = FakeRealtimeSpeechPlayer()
        let systemSpeechPlayer = FakeSystemSpeechPlayer()
        let controller = CompanionSpeechPlaybackController(
            realtimeVoiceClient: realtimeSpeechPlayer,
            systemSpeechPlayer: systemSpeechPlayer
        )

        controller.cancelGuidanceSpeech()
        #expect(realtimeSpeechPlayer.stopCount == 1)
        #expect(systemSpeechPlayer.stopCount == 0)

        controller.stopAllSpeech()
        #expect(realtimeSpeechPlayer.stopCount == 2)
        #expect(systemSpeechPlayer.stopCount == 1)
    }
}
