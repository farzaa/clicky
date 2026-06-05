//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech using macOS AVSpeechSynthesizer (local, free, no network).
//  The class name is intentionally kept the same so CompanionManager needs
//  minimal changes — only the implementation changed.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True while the synthesizer is speaking. Polled by CompanionManager
    /// to know when to fade out the transient cursor overlay.
    private(set) var isPlaying: Bool = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` using the macOS system TTS voice. Returns immediately
    /// after speech begins (does not wait for it to finish).
    func speakText(_ text: String) async throws {
        // Stop any currently running speech before starting new utterance
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // Prefer the premium Siri voices (downloaded separately in System Settings →
        // Accessibility → Spoken Content → System Voice). These sound significantly
        // more natural than the default compact voices. Fall back by quality tier
        // until we find one that's installed, then fall back to the system default.
        let premiumVoiceIdentifiers = [
            "com.apple.ttsbundle.siri_female_en-US_premium",   // Siri (US, female) — most natural
            "com.apple.ttsbundle.siri_male_en-US_premium",     // Siri (US, male)
            "com.apple.voice.enhanced.en-US.Samantha",         // Samantha Enhanced
            "com.apple.ttsbundle.Samantha-premium",            // Samantha Premium
        ]
        let selectedVoice = premiumVoiceIdentifiers
            .compactMap { AVSpeechSynthesisVoice(identifier: $0) }
            .first
            ?? AVSpeechSynthesisVoice(language: "en-US")

        utterance.voice = selectedVoice
        // Slightly faster than default (0.5) — more natural for a conversational assistant
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isPlaying = true
        speechSynthesizer.speak(utterance)
        print("🔊 Apple TTS: speaking \(text.count) characters")
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

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
