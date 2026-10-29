//
//  SystemTTSClient.swift
//  leanring-buddy
//
//  No-cost speech output using the voice configured in macOS.
//

import AVFoundation

@MainActor
final class SystemTTSClient {
    private let synthesizer = AVSpeechSynthesizer()

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    func speakText(_ text: String) {
        stopPlayback()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
