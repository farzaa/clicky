//
//  ParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription using NVIDIA's Parakeet model via FluidAudio (CoreML).
//  Models auto-download on first use. No API key or internet connection required
//  after the initial download. Runs on the Apple Neural Engine.
//
//  Requires: FluidAudio package (https://github.com/FluidInference/FluidAudio.git)
//

import AVFoundation
import FluidAudio
import Foundation

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet"

    /// Parakeet requires no Speech Recognition permission — it uses raw PCM audio.
    let requiresSpeechRecognitionPermission = false

    /// Always available since it's entirely on-device with no API key.
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Shared AsrManager — model loading is expensive, so we keep it alive
    /// in memory after the first transcription and reuse it for all subsequent ones.
    fileprivate static var sharedAsrManager: AsrManager?

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return ParakeetTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

// MARK: - Session

/// Buffers push-to-talk audio as PCM16 at 16kHz, then runs Parakeet inference
/// on key-up via FluidAudio. Mirrors the OpenAI provider's buffer-then-transcribe pattern
/// but runs entirely on device with no network call after the initial model download.
private final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Allow extra time on first use for model download + load.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 15.0

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.clicky.parakeet.session")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)

    private var bufferedPCM16Data = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var inferenceTask: Task<Void, Never>?

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    // MARK: - BuddyStreamingTranscriptionSession

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let pcm16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !pcm16Data.isEmpty else { return }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16Data.append(pcm16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let capturedAudioData = self.bufferedPCM16Data
            self.inferenceTask = Task { [weak self] in
                await self?.runInference(on: capturedAudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            self?.isCancelled = true
            self?.bufferedPCM16Data.removeAll(keepingCapacity: false)
        }
        inferenceTask?.cancel()
    }

    // MARK: - Inference

    private func runInference(on pcm16Data: Data) async {
        guard !Task.isCancelled else { return }

        let isEmpty = stateQueue.sync { isCancelled || pcm16Data.isEmpty }
        if isEmpty {
            deliverFinalTranscript("")
            return
        }

        do {
            // Convert PCM16 little-endian mono 16kHz → Float32 in [-1, 1] for FluidAudio
            let float32Samples = convertPCM16DataToFloat32Samples(pcm16Data)

            let asrManager = try await loadSharedAsrManagerIfNeeded()
            guard !Task.isCancelled, !stateQueue.sync(execute: { isCancelled }) else { return }

            var decoderState = TdtDecoderState.make()
            let transcriptionResult = try await asrManager.transcribe(float32Samples, decoderState: &decoderState)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let transcriptText = transcriptionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🎙️ Parakeet transcript: \"\(transcriptText)\"")

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Parakeet] ❌ Inference error: \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Loads (or returns the cached) shared AsrManager, downloading models from
    /// HuggingFace on first use. Uses v2 (English-only, fastest, ~600MB).
    private func loadSharedAsrManagerIfNeeded() async throws -> AsrManager {
        if let existing = ParakeetTranscriptionProvider.sharedAsrManager {
            return existing
        }

        print("⬇️ Parakeet: downloading and loading models (first use)...")
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        ParakeetTranscriptionProvider.sharedAsrManager = manager
        print("✅ Parakeet: models loaded, ready for transcription")
        return manager
    }

    /// Converts raw PCM16 little-endian mono bytes to Float32 samples in [-1.0, 1.0].
    /// FluidAudio expects 16kHz mono Float32 — the PCM16 converter already resamples to 16kHz.
    private func convertPCM16DataToFloat32Samples(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var float32Samples = [Float](repeating: 0.0, count: sampleCount)

        data.withUnsafeBytes { (rawBytes: UnsafeRawBufferPointer) in
            let int16Samples = rawBytes.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // Normalize Int16 range [-32768, 32767] to Float32 [-1.0, 1.0]
                float32Samples[i] = Float(int16Samples[i]) / 32_767.0
            }
        }

        return float32Samples
    }

    private func deliverFinalTranscript(_ text: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(text)
    }

    deinit {
        isCancelled = true
        bufferedPCM16Data.removeAll(keepingCapacity: false)
        inferenceTask?.cancel()
    }
}
