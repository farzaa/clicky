//
//  AppleTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech using macOS NSSpeechSynthesizer, which can use the
//  system voice set in Accessibility settings — including Siri voices.
//  Falls back to AVSpeechSynthesizer if NSSpeechSynthesizer fails.
//

import AppKit
import AVFoundation

@MainActor
final class AppleTTSClient: NSObject {
    /// Primary synthesizer — uses the system default voice (including Siri
    /// voices configured in System Settings → Accessibility → Spoken Content).
    private var systemSynthesizer: NSSpeechSynthesizer?

    /// Fallback synthesizer using AVSpeechSynthesizer, in case
    /// NSSpeechSynthesizer fails for any reason.
    private let fallbackSynthesizer = AVSpeechSynthesizer()

    /// Tracks whether speech is currently playing.
    private(set) var isSpeaking: Bool = false

    /// Delegate bridge that forwards NSSpeechSynthesizerDelegate callbacks
    /// back to this client. Stored separately to avoid @MainActor isolation
    /// conflicts with the delegate protocol.
    private var delegateBridge: SpeechDelegateBridge?

    override init() {
        super.init()

        let synthesizer = NSSpeechSynthesizer()
        self.systemSynthesizer = synthesizer

        let bridge = SpeechDelegateBridge { [weak self] in
            Task { @MainActor [weak self] in
                self?.isSpeaking = false
            }
        }
        self.delegateBridge = bridge
        synthesizer.delegate = bridge

        let defaultVoice = NSSpeechSynthesizer.defaultVoice
        let attributes = NSSpeechSynthesizer.attributes(forVoice: defaultVoice)
        let voiceName = attributes[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String ?? "unknown"
        print("🔊 Apple TTS: using system voice \"\(voiceName)\" (NSSpeechSynthesizer)")
    }

    /// Speaks the given text aloud using the system voice. Returns
    /// immediately after speech starts (NSSpeechSynthesizer.startSpeaking
    /// is non-blocking). Falls back to AVSpeechSynthesizer on failure.
    func speakText(_ text: String) async throws {
        stopPlayback()
        isSpeaking = true

        if let systemSynthesizer, systemSynthesizer.startSpeaking(text) {
            print("🔊 Apple TTS: speaking \(text.count) characters via system voice")
        } else {
            print("⚠️ NSSpeechSynthesizer failed, falling back to AVSpeechSynthesizer")
            speakWithFallback(text)
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        systemSynthesizer?.stopSpeaking()
        fallbackSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Fallback

    private func speakWithFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        fallbackSynthesizer.speak(utterance)
        print("🔊 Fallback TTS: speaking \(text.count) characters")
    }
}

// MARK: - Delegate Bridge

/// Separate class to handle NSSpeechSynthesizerDelegate without
/// @MainActor isolation conflicts. Calls back via a closure.
private final class SpeechDelegateBridge: NSObject, NSSpeechSynthesizerDelegate {
    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        onFinished()
    }
}
