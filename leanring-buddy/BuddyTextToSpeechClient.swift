//
//  BuddyTextToSpeechClient.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends — the same pattern
//  as BuddyChatProvider and BuddyTranscriptionProvider. ElevenLabs is the
//  cloud voice; AppleSpeechSynthesisClient is the on-device voice used by
//  Local Mode so the whole answer loop works offline.
//

import Foundation

/// The contract CompanionManager relies on (it was ElevenLabsTTSClient's
/// implicit contract before Local Mode existed):
/// - `speakText` returns as soon as playback starts, not when it ends.
/// - `isPlaying` stays true until playback finishes or is stopped — the
///   transient-cursor hide loop polls it every 200ms and waits on it.
/// - `stopPlayback` silences audio synchronously.
@MainActor
protocol BuddyTextToSpeechClient: AnyObject {
    func speakText(_ text: String) async throws
    var isPlaying: Bool { get }
    func stopPlayback()
}

// ElevenLabsTTSClient already satisfies the contract exactly — the protocol
// was written around its existing behavior.
extension ElevenLabsTTSClient: BuddyTextToSpeechClient {}
