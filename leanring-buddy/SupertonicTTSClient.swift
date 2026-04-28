//
//  SupertonicTTSClient.swift
//  leanring-buddy
//
//  On-device TTS using the Supertonic ONNX engine (66M params, ~167× realtime
//  on Apple Silicon). Models auto-download from HuggingFace on first use (~200MB).
//  Interface mirrors ElevenLabsTTSClient so CompanionManager can swap between them.
//

import AVFoundation
import Foundation

@MainActor
final class SupertonicTTSClient {

    /// Voice to use for synthesis. Matches upstream voice_styles/*.json filenames.
    /// Available: M1–M5 (male), F1–F5 (female).
    var selectedVoice: String {
        didSet {
            UserDefaults.standard.set(selectedVoice, forKey: "supertonicSelectedVoice")
        }
    }

    private(set) var isPlaying: Bool = false

    private var loadedEngine: SupertonicTTS?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// UUID used to detect when a new speakText() call cancels the current one.
    private var activePlaybackSession: UUID?

    // MARK: - Model paths

    private static let huggingFaceBaseURL = "https://huggingface.co/Supertone/supertonic-2/resolve/main"

    private static var supertonicModelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clicky/models/supertonic", isDirectory: true)
    }

    private static var onnxModelDir: URL {
        supertonicModelDir.appendingPathComponent("onnx", isDirectory: true)
    }

    private static var voiceStylesDir: URL {
        supertonicModelDir.appendingPathComponent("voice_styles", isDirectory: true)
    }

    // MARK: - Init

    init() {
        self.selectedVoice = UserDefaults.standard.string(forKey: "supertonicSelectedVoice") ?? "M1"
    }

    // MARK: - Public interface

    /// Synthesizes `text` using the selected voice and plays back the audio.
    /// Downloads ONNX models from HuggingFace on first call (~200MB one-time).
    /// Throws on network, model-loading, or synthesis errors.
    func speakText(_ text: String) async throws {
        stopPlayback()

        let session = UUID()
        activePlaybackSession = session

        // Download models and the selected voice style file if not already on disk
        try await ensureModelsAndVoiceDownloaded(voiceId: selectedVoice)
        guard activePlaybackSession == session else { return }

        // Load the ONNX engine (cached in memory after first load)
        let tts = try loadEngineIfNeeded()
        guard activePlaybackSession == session else { return }

        // Synthesize — runs on CPU/ANE via ONNX Runtime, fast enough for main thread
        let voiceStylePath = Self.voiceStylesDir.appendingPathComponent("\(selectedVoice).json").path
        let result = try tts.synthesize(text: text, lang: "en", voiceStylePath: voiceStylePath, speed: 1.05)
        guard activePlaybackSession == session else { return }

        let samples = result.wav
        guard !samples.isEmpty else {
            throw NSError(domain: "SupertonicTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Supertonic returned empty audio"])
        }

        let sampleRate = tts.sampleRate

        // Build a Float32 mono AVAudioPCMBuffer from the raw samples
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SupertonicTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"])
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SupertonicTTS", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
        }

        buffer.frameLength = frameCount
        for i in 0..<samples.count { channelData[i] = samples[i] }

        // Wire up AVAudioEngine and start playback
        let avEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        avEngine.attach(player)
        avEngine.connect(player, to: avEngine.mainMixerNode, format: format)
        audioEngine = avEngine
        playerNode = player

        isPlaying = true
        try avEngine.start()
        player.play()

        print("🔊 Supertonic TTS: playing \(samples.count / sampleRate)s audio, voice \(selectedVoice)")

        // Suspend the caller until playback finishes (or stopPlayback() cancels the session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { continuation.resume(); return }
                    if self.activePlaybackSession == session {
                        self.isPlaying = false
                        self.tearDownAudioEngine()
                    }
                    continuation.resume()
                }
            }
        }
    }

    /// Stops any in-progress synthesis or playback immediately.
    func stopPlayback() {
        activePlaybackSession = nil
        tearDownAudioEngine()
        isPlaying = false
    }

    // MARK: - Model download

    private func ensureModelsAndVoiceDownloaded(voiceId: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.onnxModelDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.voiceStylesDir, withIntermediateDirectories: true)

        let requiredOnnxFiles = [
            "duration_predictor.onnx",
            "text_encoder.onnx",
            "vector_estimator.onnx",
            "vocoder.onnx",
            "tts.json",
            "unicode_indexer.json",
        ]

        for filename in requiredOnnxFiles {
            let destinationURL = Self.onnxModelDir.appendingPathComponent(filename)
            if !fm.fileExists(atPath: destinationURL.path) {
                print("⬇️ Supertonic: downloading \(filename)...")
                try await downloadFileFromHuggingFace(remotePath: "onnx/\(filename)", to: destinationURL)
            }
        }

        let voiceStyleDestinationURL = Self.voiceStylesDir.appendingPathComponent("\(voiceId).json")
        if !fm.fileExists(atPath: voiceStyleDestinationURL.path) {
            print("⬇️ Supertonic: downloading voice style \(voiceId)...")
            try await downloadFileFromHuggingFace(remotePath: "voice_styles/\(voiceId).json",
                                                   to: voiceStyleDestinationURL)
        }
    }

    private func downloadFileFromHuggingFace(remotePath: String, to destinationURL: URL) async throws {
        guard let downloadURL = URL(string: "\(Self.huggingFaceBaseURL)/\(remotePath)") else {
            throw NSError(domain: "SupertonicTTS", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HuggingFace URL for \(remotePath)"])
        }

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "SupertonicTTS", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Download failed for \(remotePath)"])
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    // MARK: - Engine loading

    private func loadEngineIfNeeded() throws -> SupertonicTTS {
        if let loadedEngine { return loadedEngine }

        print("🔧 Supertonic: loading ONNX engine...")
        let engine = try supertonicLoadEngine(onnxDir: Self.onnxModelDir.path)
        loadedEngine = engine
        print("✅ Supertonic: engine ready")
        return engine
    }

    // MARK: - Audio teardown

    private func tearDownAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }
}
