//
//  MicrophoneCaptureService.swift
//  Yapr
//
//  Captures microphone audio with `AVAudioEngine` and forwards every buffer
//  into the active `BuddyStreamingTranscriptionSession` (AssemblyAI v3 in
//  v1). Also computes a smoothed RMS audio-power level so the orb can
//  pulse and the in-orb waveform can react to the user's voice.
//
//  This is the iOS-flavored equivalent of the macOS app's
//  `BuddyDictationManager.swift`, but trimmed to just what the voice orb
//  needs — no draft-text plumbing, no provider selection, no permission
//  cooldowns. Microphone permission is owned by `YaprViewModel`.
//

import AVFoundation
import Combine
import Foundation

import ClickyShared

@MainActor
final class MicrophoneCaptureService: ObservableObject {
    /// Smoothed RMS of the current mic input, normalized to 0...1. Drives
    /// the orb's pulse intensity and the waveform bars during listening.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0

    private let audioEngine = AVAudioEngine()
    private let transcriptionProvider: any BuddyTranscriptionProvider
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?

    private var onTranscriptUpdate: ((String) -> Void)?
    private var onFinalTranscriptReady: ((String) -> Void)?
    private var onError: ((Error) -> Void)?

    init(transcriptionProvider: any BuddyTranscriptionProvider) {
        self.transcriptionProvider = transcriptionProvider
    }

    /// Opens an AssemblyAI streaming session and starts the mic engine.
    /// Callbacks fire on the main actor as transcripts arrive.
    /// Throws if the AssemblyAI websocket can't be opened or the audio
    /// engine fails to start.
    func startCapturing(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        // Tear down any prior session before opening a new one.
        await cancelCurrentCapture()

        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let session = try await transcriptionProvider.startStreamingSession(
            keyterms: keyterms,
            onTranscriptUpdate: { transcriptText in
                Task { @MainActor in
                    onTranscriptUpdate(transcriptText)
                }
            },
            onFinalTranscriptReady: { transcriptText in
                Task { @MainActor in
                    onFinalTranscriptReady(transcriptText)
                }
            },
            onError: { error in
                Task { @MainActor in
                    onError(error)
                }
            }
        )

        self.activeTranscriptionSession = session

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Asks the AssemblyAI session to deliver a final transcript and stops
    /// the audio engine. The final transcript will arrive via the
    /// `onFinalTranscriptReady` callback registered in `startCapturing`.
    func requestFinalTranscriptAndStop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.requestFinalTranscript()
        currentAudioPowerLevel = 0
    }

    /// Cancels the current capture without producing a transcript, e.g. on
    /// app backgrounding or an explicit cancel from the UI.
    func cancelCurrentCapture() async {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil
        onTranscriptUpdate = nil
        onFinalTranscriptReady = nil
        onError = nil
        currentAudioPowerLevel = 0
    }

    private nonisolated func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Smooth the curve so the orb pulses, not jitters. Same easing
            // formula as the macOS app's BuddyDictationManager so the visual
            // language reads identically across platforms.
            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel
        }
    }
}
