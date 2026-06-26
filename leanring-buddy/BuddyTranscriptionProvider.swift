//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case realtime = "realtime"
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        SpiderDiagnostics.event("transcription provider selected")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .realtime {
            return SpiderRealtimeFallbackTranscriptionProvider()
        }

        return SpiderRealtimeFallbackTranscriptionProvider()
    }
}

final class SpiderRealtimeFallbackTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "OpenAI Realtime"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private let realtimeProvider = OpenAIRealtimeTranscriptionProvider()
    private let appleSpeechProvider = AppleSpeechTranscriptionProvider()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        do {
            return try await realtimeProvider.startStreamingSession(
                keyterms: keyterms,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        } catch {
            SpiderDiagnostics.event("realtime transcription unavailable, falling back to apple speech")
            return try await appleSpeechProvider.startStreamingSession(
                keyterms: keyterms,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        }
    }
}
