//
//  CompanionVisionGuideErrorPresentationPolicy.swift
//  leanring-buddy
//
//  Maps local Vision guide client errors to bounded UI/speech side effects.
//

import Foundation

enum CompanionVisionGuideErrorPresentationPolicy {
    struct Presentation: Equatable {
        let actions: [Action]
    }

    enum Action: Equatable {
        case markLoggedOut(message: String, clearStoredToken: Bool)
        case showPanel
        case recordDiagnosticEvent(DiagnosticEvent)
        case speakSystemText(String)
    }

    enum DiagnosticEvent: Equatable {
        case missingScreenshot
        case missingUserTranscript
        case clientValidationFailed

        var message: StaticString {
            switch self {
            case .missingScreenshot:
                return "vision guide blocked before upload because screenshot was missing"
            case .missingUserTranscript:
                return "vision guide blocked before upload because transcript was empty"
            case .clientValidationFailed:
                return "vision guide client validation failed"
            }
        }
    }

    static func presentation(for error: OpenAIVisionGuideClientError) -> Presentation {
        switch error {
        case .missingSessionToken:
            return Presentation(actions: [
                .markLoggedOut(message: "Sign in to continue.", clearStoredToken: false),
                .showPanel,
                .speakSystemText("Sign in to Spider before I can look at your screen."),
            ])
        case .missingScreenshot:
            return Presentation(actions: [
                .recordDiagnosticEvent(.missingScreenshot),
                .speakSystemText("I need screen recording access before I can guide the next step on your screen."),
                .showPanel,
            ])
        case .missingUserTranscript:
            return Presentation(actions: [
                .recordDiagnosticEvent(.missingUserTranscript),
                .speakSystemText("Tell me what you want help with, then I can look at the screen and guide the next step."),
            ])
        case .invalidWorkerResponse, .oversizedGuideResponse, .invalidGuideResponse:
            return Presentation(actions: [
                .recordDiagnosticEvent(.clientValidationFailed),
                .speakSystemText(CompanionSpeechPolicy.guidanceUnavailableMessage),
            ])
        }
    }
}
