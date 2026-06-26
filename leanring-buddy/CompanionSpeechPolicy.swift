//
//  CompanionSpeechPolicy.swift
//  leanring-buddy
//
//  Bounded speech copy decisions for CompanionManager. Keep this policy pure so
//  speech fallbacks stay testable and never depend on raw Worker error bodies.
//

import Foundation

enum CompanionSpeechPolicy {
    static func systemText(_ text: String) -> String {
        text.spiderSanitizedShortDialogue(
            maxCharacters: 140,
            maxWords: 18,
            maxSentences: 2
        )
    }

    static func guidanceText(_ text: String) -> String {
        text.spiderSanitizedShortDialogue(
            maxCharacters: 220,
            maxWords: 22,
            maxSentences: 2
        )
    }

    static func accountBlockedMessage(for accountState: SpiderAccountState) -> String? {
        switch accountState {
        case .loggedOut:
            return "Sign in first."
        case .checking:
            return "Checking account. Try again."
        case .paymentRequired:
            return "Upgrade required."
        case .error:
            return "Sign in again."
        case .active, .trial:
            return nil
        }
    }

    static func permissionsBlockedMessage(
        hasAccessibilityPermission: Bool,
        hasMicrophonePermission: Bool,
        hasScreenRecordingPermission: Bool,
        hasScreenContentPermission: Bool
    ) -> String {
        if !hasAccessibilityPermission {
            return "Grant Accessibility first."
        }

        if !hasMicrophonePermission {
            return "Grant Microphone first."
        }

        if !hasScreenRecordingPermission || !hasScreenContentPermission {
            return "Grant screen permissions first."
        }

        return "Finish permissions in Spider."
    }

    static let screenGuidanceBlockedMessage = "Grant screen permissions first."

    static let guidanceUnavailableMessage =
        "Spider could not get guidance from the server. Check your login, subscription, and network connection."

    static func workerErrorFallbackMessage(for error: SpiderWorkerClientError) -> String {
        if error.isAuthenticationExpired {
            return "Your Spider session expired. Sign in again before I can look at your screen."
        }

        if error.isPaymentRequired {
            return "Your Spider account needs an active subscription before I can use AI guidance."
        }

        if error.isRateLimited {
            return "You hit your Spider usage limit for now. Try again later."
        }

        if error.isPayloadTooLarge {
            return "That screenshot is too large to send safely. Try again with fewer displays connected."
        }

        return guidanceUnavailableMessage
    }
}
