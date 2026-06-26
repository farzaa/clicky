//
//  BuddyDictationErrorPresentationPolicy.swift
//  leanring-buddy
//
//  Maps internal voice/transcription errors to short user-facing messages.
//

import Foundation

enum BuddyDictationErrorPresentationPolicy {
    static func voiceInputFailureMessage(
        for error: SpiderWorkerClientError,
        fallback: String
    ) -> String {
        if error.isAuthenticationExpired {
            return "sign in again before using voice."
        }
        if error.isPaymentRequired {
            return "an active Spider subscription is required for voice."
        }
        if error.isRateLimited {
            return "voice usage limit reached. try again later."
        }
        if error.isPayloadTooLarge {
            return "that voice request is too large. try a shorter ask."
        }
        return fallback
    }

    static func voiceInputFailureMessage(
        for error: OpenAIRealtimeTranscriptionProviderError,
        fallback: String
    ) -> String {
        switch error {
        case .serverEventTooLarge, .clientEventTooLarge, .transcriptTooLarge:
            return "that voice request was too long. try a shorter ask."
        case .invalidRealtimeURL, .realtimeReturnedError, .webSocketNotConnected, .invalidClientEvent:
            return fallback
        }
    }

    static func voiceInputFailureMessage(
        for error: OpenAIRealtimeVoiceClientError,
        fallback: String
    ) -> String {
        switch error {
        case .missingSessionToken:
            return "sign in again before using voice."
        case .clientSecretResponseTooLarge:
            return "voice setup response was too large. try again."
        case .clientEventTooLarge:
            return "that voice response was too large. try a shorter ask."
        case .invalidWorkerResponse, .invalidRealtimeURL, .webSocketNotConnected, .invalidClientEvent, .realtimeError:
            return fallback
        }
    }
}
