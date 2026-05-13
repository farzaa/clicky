//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String, volume: Double = 1.0) async throws {
        let clampedVolume = Self.clampedPlaybackVolume(volume)
        guard clampedVolume > 0 else {
            DotDebugLogger.log("tts.elevenlabs", "request skipped because speech volume is muted", metadata: [
                "textLength": text.count
            ])
            return
        }

        let requestStartedAt = Date()
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        if let installToken = DotInstallTokenStore.currentInstallToken() {
            request.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        DotDebugLogger.log("tts.elevenlabs", "request started", metadata: [
            "textLength": text.count,
            "volume": clampedVolume
        ])
        let (data, response) = try await session.data(for: request)
        let requestDurationMs = Int((Date().timeIntervalSince(requestStartedAt) * 1_000).rounded())

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            DotAnalytics.trackInferenceEndpointResult(
                endpoint: "tts",
                statusCode: httpResponse.statusCode,
                durationMs: requestDurationMs,
                provider: "elevenlabs",
                model: "eleven_flash_v2_5"
            )
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: httpResponse.statusCode,
                responseBody: errorBody,
                fallbackEndpoint: "tts"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        DotDebugLogger.log("tts.elevenlabs", "audio received", metadata: [
            "textLength": text.count,
            "audioKilobytes": data.count / 1024,
            "requestDurationMs": requestDurationMs
        ])
        DotAnalytics.trackInferenceEndpointResult(
            endpoint: "tts",
            statusCode: httpResponse.statusCode,
            durationMs: requestDurationMs,
            provider: "elevenlabs",
            model: "eleven_flash_v2_5"
        )
        let player = try AVAudioPlayer(data: data)
        player.volume = Float(clampedVolume)
        self.audioPlayer = player
        player.play()
        DotDebugLogger.log("tts.elevenlabs", "playback started", metadata: [
            "audioDurationSeconds": player.duration,
            "audioKilobytes": data.count / 1024,
            "volume": clampedVolume
        ])
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    func setPlaybackVolume(_ volume: Double) {
        let clampedVolume = Self.clampedPlaybackVolume(volume)
        audioPlayer?.volume = Float(clampedVolume)
        if clampedVolume <= 0 {
            stopPlayback()
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Awaits until the current playback finishes (or cancellation fires).
    /// Returns immediately if nothing is playing. Used by per-step narration
    /// to play chunks back-to-back without overlapping.
    func awaitPlaybackCompletion() async {
        let playbackWaitStartedAt = Date()
        let didStartWithActivePlayback = audioPlayer?.isPlaying == true
        while audioPlayer?.isPlaying == true {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if didStartWithActivePlayback {
            DotDebugLogger.log("tts.elevenlabs", "playback completed", metadata: [
                "waitDurationMs": Int((Date().timeIntervalSince(playbackWaitStartedAt) * 1_000).rounded())
            ])
        }
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private static func clampedPlaybackVolume(_ volume: Double) -> Double {
        min(max(volume, 0), 1)
    }
}
