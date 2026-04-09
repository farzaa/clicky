//
//  LocalSpeechSynthesizerClient.swift
//  leanring-buddy
//
//  Created by MD Sahil AK on 09/04/26.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechSynthesizerClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        speechSynthesizer.speak(utterance)
    }

    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
