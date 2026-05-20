//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  Neural TTS client that speaks text via a locally-running Kokoro-FastAPI server.
//  Kokoro is an open-source neural TTS model that sounds significantly more natural
//  than macOS AVSpeechSynthesizer. It runs at http://localhost:8880 and exposes an
//  OpenAI-compatible /v1/audio/speech endpoint.
//
//  Setup (one time):
//    pip install kokoro-fastapi
//    kokoro    ← starts the server; keep it running alongside Ollama
//
//  More info: https://github.com/remsky/Kokoro-FastAPI
//
//  This client is the preferred TTS backend. CompanionManager falls back to
//  LocalTTSClient (AVSpeechSynthesizer) if this server is not reachable.
//

import AVFoundation
import Foundation

@MainActor
final class KokoroTTSClient {
    /// Base URL of the local Kokoro-FastAPI server.
    private static let kokoroBaseURL = "http://localhost:8880"
    private static let speechEndpointPath = "/v1/audio/speech"

    /// The Kokoro voice to use. Popular options:
    ///   af_sky    — American female, warm and clear (default)
    ///   af_bella  — American female, expressive
    ///   am_adam   — American male, neutral
    ///   am_michael — American male, deeper
    ///   bf_emma   — British female
    ///   bm_george — British male
    /// Exposed as internal so the panel status row can display the active voice name.
    static let defaultVoice = "af_sky"

    private let speechEndpointURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so audio
    /// finishes even if no external reference to this client is held.
    private var audioPlayer: AVAudioPlayer?

    init() {
        self.speechEndpointURL = URL(string: Self.kokoroBaseURL + Self.speechEndpointPath)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false  // Fail fast if Kokoro isn't running
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public Interface

    /// Sends `text` to the Kokoro server and plays the resulting audio.
    /// Returns immediately after playback starts (non-blocking).
    /// Throws if the server is unreachable — CompanionManager catches this
    /// and falls back to LocalTTSClient automatically.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        var request = URLRequest(url: speechEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // OpenAI-compatible TTS request body
        let requestBody: [String: Any] = [
            "model": "kokoro",
            "input": trimmedText,
            "voice": Self.defaultVoice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (audioData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KokoroTTSError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: audioData, encoding: .utf8) ?? "Unknown error"
            throw KokoroTTSError.serverError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: audioData)
        self.audioPlayer = player
        player.play()
        print("🔊 Kokoro TTS: playing \(audioData.count / 1024)KB audio for \(trimmedText.count) chars")
    }

    /// Whether Kokoro TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Reachability Check

    /// Quickly checks whether the Kokoro server is currently running.
    /// Used by CompanionManager on startup to decide which TTS backend to use,
    /// and by the panel UI to show the server status indicator.
    static func isServerReachable() async -> Bool {
        guard let healthURL = URL(string: kokoroBaseURL) else { return false }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }
}

// MARK: - Error Types

enum KokoroTTSError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)
    case serverNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Kokoro TTS returned an invalid response."
        case .serverError(let statusCode, let body):
            return "Kokoro TTS server error (\(statusCode)): \(body)"
        case .serverNotRunning:
            return "Kokoro TTS server is not running. Start it with: kokoro"
        }
    }
}
