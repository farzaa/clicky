//
//  CompanionVisionGuideErrorPresentationPolicyTests.swift
//  leanring-buddyTests
//
//  Keeps Vision guide client error presentation out of CompanionManager.
//

import Testing
@testable import Spider

@MainActor
struct CompanionVisionGuideErrorPresentationPolicyTests {
    @Test func missingSessionTokenLogsOutShowsPanelAndSpeaks() {
        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .missingSessionToken
            ).actions == [
                .markLoggedOut(message: "Sign in to continue.", clearStoredToken: false),
                .showPanel,
                .speakSystemText("Sign in to Spider before I can look at your screen."),
            ]
        )
    }

    @Test func missingScreenshotKeepsScreenPermissionPresentation() {
        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .missingScreenshot
            ).actions == [
                .recordDiagnosticEvent(.missingScreenshot),
                .speakSystemText("I need screen recording access before I can guide the next step on your screen."),
                .showPanel,
            ]
        )
    }

    @Test func missingTranscriptKeepsBoundedPromptPresentation() {
        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .missingUserTranscript
            ).actions == [
                .recordDiagnosticEvent(.missingUserTranscript),
                .speakSystemText("Tell me what you want help with, then I can look at the screen and guide the next step."),
            ]
        )
    }

    @Test func invalidVisionResponsesUseSanitizedFallbackPresentation() {
        let expectedActions: [CompanionVisionGuideErrorPresentationPolicy.Action] = [
            .recordDiagnosticEvent(.clientValidationFailed),
            .speakSystemText(CompanionSpeechPolicy.guidanceUnavailableMessage),
        ]

        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .invalidWorkerResponse
            ).actions == expectedActions
        )
        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .oversizedGuideResponse
            ).actions == expectedActions
        )
        #expect(
            CompanionVisionGuideErrorPresentationPolicy.presentation(
                for: .invalidGuideResponse
            ).actions == expectedActions
        )
    }
}
