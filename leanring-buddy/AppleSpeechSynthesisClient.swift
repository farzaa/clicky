//
//  AppleSpeechSynthesisClient.swift
//  leanring-buddy
//
//  On-device text-to-speech for Local Mode, backed by AVSpeechSynthesizer.
//  More robotic than ElevenLabs — that's the tradeoff for a voice that
//  works with wifi off and never sends a word anywhere.
//

import AVFoundation
import Foundation

@MainActor
final class AppleSpeechSynthesisClient: NSObject, BuddyTextToSpeechClient {
    /// Must stay strongly referenced for the whole utterance — if the
    /// synthesizer deallocates, speech stops and didFinish never fires.
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True from speech start until the utterance finishes or is stopped.
    /// Flipped false by the delegate callbacks below — if it never flips,
    /// CompanionManager's transient-hide loop would wait forever.
    private(set) var isPlaying = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` with the best installed US English voice. Returns as
    /// soon as speech is queued — the same "returns when playback starts"
    /// contract as the ElevenLabs client.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        // Nothing to say — return without arming isPlaying, or the empty
        // utterance never fires didFinish and the transient-hide loop hangs.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableEnglishVoice()

        isPlaying = true
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
    }

    /// Highest-quality installed en-US voice. Premium and enhanced voices
    /// only exist if the user downloaded them in System Settings → Spoken
    /// Content — the compact default is the floor, not the goal.
    private static func bestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in voice.language == "en-US" }
        let premiumVoice = englishVoices.first { voice in voice.quality == .premium }
        let enhancedVoice = englishVoices.first { voice in voice.quality == .enhanced }
        return premiumVoice ?? enhancedVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension AppleSpeechSynthesisClient: AVSpeechSynthesizerDelegate {
    // Delegate callbacks arrive on an arbitrary queue — hop back to the
    // main actor before touching isPlaying.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}
