//
//  CompanionSystemSpeechPlayer.swift
//  leanring-buddy
//
//  Narrow system speech fallback used when Realtime voice is unavailable.
//

import AVFoundation

@MainActor
final class CompanionSystemSpeechPlayer {
    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String) {
        stop()
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}
