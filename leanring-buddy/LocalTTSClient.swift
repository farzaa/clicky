//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  Speaks text aloud using the macOS AVSpeechSynthesizer — fully local,
//  no API keys, no network calls. Uses whatever voice the user has configured
//  in System Settings > Accessibility > Spoken Content.
//
//  Designed as a drop-in replacement for ElevenLabsTTSClient with the same
//  public interface so CompanionManager needs minimal changes.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public Interface

    /// Speaks `text` aloud using the macOS speech synthesizer.
    /// Returns immediately after speech begins — does not block until playback finishes.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Stop any currently-playing speech so the new response starts immediately
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmedText)

        // Use the best available Siri voice for the user's preferred language.
        // Falls back to the system default voice if no enhanced voice is installed.
        if let bestAvailableVoice = Self.selectBestAvailableVoice() {
            utterance.voice = bestAvailableVoice
        }

        // Slightly slower than default (1.0) for better clarity during voice assistant use
        utterance.rate = 0.8
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)
        print("🔊 Local TTS: speaking \(trimmedText.count) characters")
    }

    /// Whether the synthesizer is currently speaking.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Voice Selection

    /// Picks the best available English voice in priority order:
    /// 1. A premium/enhanced Siri voice (highest quality, requires download in System Settings)
    /// 2. Any enhanced-quality voice in the user's preferred language
    /// 3. The default system voice
    private static func selectBestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let preferredLanguageCode = Locale.preferredLanguages.first ?? "en-US"

        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        print(allVoices)

        // Prefer premium voices (Siri-quality) in the user's preferred language
        let premiumVoicesForPreferredLanguage = allVoices.filter { voice in
            voice.language.hasPrefix(preferredLanguageCode.prefix(2))
            && voice.quality == .premium
        }
        if let premiumVoice = premiumVoicesForPreferredLanguage.first {
            return premiumVoice
        }

        // Fall back to enhanced (non-premium but better than default) voices
        let enhancedVoicesForPreferredLanguage = allVoices.filter { voice in
            voice.language.hasPrefix(preferredLanguageCode.prefix(2))
            && voice.quality == .enhanced
        }
        if let enhancedVoice = enhancedVoicesForPreferredLanguage.first {
            return enhancedVoice
        }

        // Last resort: let the system pick its default voice
        return AVSpeechSynthesisVoice(language: preferredLanguageCode)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension LocalTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        print("🔊 Local TTS: finished speaking")
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        print("🔊 Local TTS: speech cancelled")
    }
}
