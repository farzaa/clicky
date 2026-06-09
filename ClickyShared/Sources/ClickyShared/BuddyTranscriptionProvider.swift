//
//  BuddyTranscriptionProvider.swift
//  ClickyShared
//
//  Protocol surface for voice transcription backends. Lifted from the
//  open-source Clicky macOS app, made public for the iOS host app.
//

import AVFoundation
import Foundation

/// A live streaming transcription session. The owner appends audio buffers as
/// they arrive from the microphone, then calls `requestFinalTranscript()` when
/// the user is done speaking.
public protocol BuddyStreamingTranscriptionSession: AnyObject {
    /// Maximum time the caller should wait for an explicit final transcript
    /// after `requestFinalTranscript()` before falling back to the latest
    /// partial transcript.
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }

    /// Forwards a microphone audio buffer to the streaming backend.
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)

    /// Signals that the user has finished speaking and a final transcript
    /// should be produced as soon as possible.
    func requestFinalTranscript()

    /// Tears down the session and releases any underlying network resources.
    func cancel()
}

/// A transcription backend (websocket-based or upload-based) that can produce
/// a final transcript from a stream of microphone audio.
public protocol BuddyTranscriptionProvider {
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
