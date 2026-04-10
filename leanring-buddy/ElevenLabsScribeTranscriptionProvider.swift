//
//  ElevenLabsScribeTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming transcription provider backed by ElevenLabs Scribe v2 Realtime.
//  Fetches a short-lived single-use token from the Cloudflare Worker proxy,
//  opens a WebSocket to the ElevenLabs Scribe API, streams base64-encoded
//  PCM16 audio as JSON chunks, and delivers finalized text on commit.
//

import AVFoundation
import Foundation

struct ElevenLabsScribeTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class ElevenLabsScribeTranscriptionProvider: BuddyTranscriptionProvider {
    /// URL for the Cloudflare Worker endpoint that returns a short-lived
    /// ElevenLabs Scribe single-use token. The real API key never leaves the server.
    private static let tokenProxyURL = "https://your-worker-name.your-subdomain.workers.dev/transcribe-token"

    let displayName = "ElevenLabs Scribe"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after
    /// a few rapid reconnections to the same host.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        if !keyterms.isEmpty {
            print("🎙️ ElevenLabs Scribe: keyterms are not supported and will be ignored")
        }

        // Fetch a fresh single-use token from the proxy before each session.
        // ElevenLabs tokens are single-use with a 15-minute expiry.
        let temporaryToken = try await fetchTemporaryToken()
        print("🎙️ ElevenLabs Scribe: fetched single-use token (\(temporaryToken.prefix(20))...)")

        let session = ElevenLabsScribeTranscriptionSession(
            temporaryToken: temporaryToken,
            urlSession: sharedWebSocketURLSession,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// Calls the Cloudflare Worker to get a short-lived ElevenLabs Scribe token.
    private func fetchTemporaryToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "Failed to fetch ElevenLabs Scribe token (HTTP \(statusCode)): \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class ElevenLabsScribeTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    // MARK: - Inbound message decodable types

    private struct ElevenLabsMessageEnvelope: Decodable {
        let type: String
    }

    private struct ElevenLabsTranscriptMessage: Decodable {
        let type: String
        let transcript: String?
    }

    private struct ElevenLabsErrorMessage: Decodable {
        let type: String
        let reason: String?
    }

    // MARK: - Constants

    private static let websocketBaseURLString = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    private static let targetSampleRate = 16_000.0

    /// How long to wait for the committed_transcript message after sending the
    /// commit chunk before falling back to the latest partial transcript.
    private static let committedTranscriptGracePeriodSeconds = 1.0

    /// Used by BuddyDictationManager as an outer fallback timeout in case the
    /// session never calls onFinalTranscriptReady.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    // MARK: - Dependencies

    private let urlSession: URLSession
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    // MARK: - Infrastructure

    /// All mutable session state is read and written exclusively on this queue
    /// to prevent data races across the WebSocket receive callback and the
    /// dictation manager's audio tap.
    private let stateQueue = DispatchQueue(label: "com.learningbuddy.elevenlabs.state")

    /// Sends are dispatched on a separate queue so audio chunk sends never
    /// block state reads in the receive path.
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.elevenlabs.send")

    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)

    // MARK: - WebSocket

    private var webSocketTask: URLSessionWebSocketTask?

    // MARK: - Ready handshake state

    /// Suspended by open() until session_started is received from ElevenLabs.
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Guards against resuming the continuation more than once (e.g. if an
    /// error arrives right as session_started does).
    private var hasResolvedReadyContinuation = false

    // MARK: - Session state

    /// The most recent partial transcript text received from ElevenLabs.
    /// Used as fallback if the grace period expires before committed_transcript arrives.
    private var latestPartialTranscriptText = ""

    /// Prevents delivering the final transcript more than once.
    private var hasDeliveredFinalTranscript = false

    /// Set to true after requestFinalTranscript() sends the commit chunk.
    /// While true, incoming committed_transcript is treated as the final answer.
    private var isAwaitingCommittedTranscript = false

    /// Cancelled if committed_transcript arrives before the deadline fires.
    private var committedTranscriptGraceDeadlineWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(
        temporaryToken: String,
        urlSession: URLSession,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.temporaryToken = temporaryToken
        self.urlSession = urlSession
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    private let temporaryToken: String

    // MARK: - BuddyStreamingTranscriptionSession

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(temporaryToken: temporaryToken)

        let webSocketTask = urlSession.webSocketTask(with: websocketURL)
        self.webSocketTask = webSocketTask

        // Install the receive loop before resuming so session_started cannot
        // arrive before we are ready to handle it.
        receiveNextMessage()
        webSocketTask.resume()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        // ElevenLabs requires audio as base64-encoded PCM inside a JSON text frame,
        // unlike AssemblyAI which accepted raw binary frames.
        let audioBase64 = audioPCM16Data.base64EncodedString()
        sendAudioChunk(base64EncodedAudio: audioBase64, commit: false)
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingCommittedTranscript = true
            self.scheduleCommittedTranscriptGraceDeadline()
        }

        // Sending a commit chunk with an empty audio payload signals ElevenLabs
        // to finalize the current transcription and return committed_transcript.
        // This replaces AssemblyAI's {"type":"ForceEndpoint"} control message.
        sendAudioChunk(base64EncodedAudio: "", commit: true)
    }

    func cancel() {
        stateQueue.async {
            self.committedTranscriptGraceDeadlineWorkItem?.cancel()
            self.committedTranscriptGraceDeadlineWorkItem = nil
        }

        // ElevenLabs has no explicit Terminate message — closing the socket is sufficient.
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - WebSocket receive loop

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNextMessage()

            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(ElevenLabsMessageEnvelope.self, from: messageData)

            switch envelope.type {
            case "session_started":
                // Session is ready to receive audio
                resolveReadyContinuationIfNeeded(with: .success(()))

            case "partial_transcript":
                let transcriptMessage = try JSONDecoder().decode(ElevenLabsTranscriptMessage.self, from: messageData)
                let partialText = transcriptMessage.transcript?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                stateQueue.async {
                    if !partialText.isEmpty {
                        self.latestPartialTranscriptText = partialText
                        self.onTranscriptUpdate(partialText)
                    }
                }

            case "committed_transcript":
                let transcriptMessage = try JSONDecoder().decode(ElevenLabsTranscriptMessage.self, from: messageData)
                let committedText = transcriptMessage.transcript?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                stateQueue.async {
                    guard self.isAwaitingCommittedTranscript else { return }
                    self.committedTranscriptGraceDeadlineWorkItem?.cancel()
                    self.committedTranscriptGraceDeadlineWorkItem = nil
                    self.deliverFinalTranscriptIfNeeded(committedText)
                }

            case "auth_error", "quota_exceeded", "rate_limited", "chunk_size_exceeded":
                let errorMessage = try JSONDecoder().decode(ElevenLabsErrorMessage.self, from: messageData)
                let errorText = errorMessage.reason ?? "ElevenLabs Scribe returned \(envelope.type)"
                failSession(with: ElevenLabsScribeTranscriptionProviderError(message: errorText))

            default:
                // Other message types (e.g. insufficient_audio_activity) are silently ignored
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    // MARK: - Grace period deadline

    /// Schedules a fallback deadline. If committed_transcript does not arrive
    /// within the grace period, the best available partial text is delivered.
    private func scheduleCommittedTranscriptGraceDeadline() {
        committedTranscriptGraceDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.latestPartialTranscriptText)
            }
        }

        committedTranscriptGraceDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.committedTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    // MARK: - Final transcript delivery

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        committedTranscriptGraceDeadlineWorkItem?.cancel()
        committedTranscriptGraceDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Audio sending

    /// Sends an audio chunk to ElevenLabs as a JSON text WebSocket frame.
    /// When commit is true, the empty audio payload signals end of speech.
    private func sendAudioChunk(base64EncodedAudio: String, commit: Bool) {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64EncodedAudio,
            "commit": commit,
            "sample_rate": 16000
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    // MARK: - Error handling

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))

        stateQueue.async {
            if self.isAwaitingCommittedTranscript
                && !self.hasDeliveredFinalTranscript
                && !self.latestPartialTranscriptText.isEmpty {
                print("[ElevenLabs Scribe] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(self.latestPartialTranscriptText)
                return
            }
            print("[ElevenLabs Scribe] ❌ Session failed with error: \(error.localizedDescription)")
            self.onError(error)
        }
    }

    // MARK: - Ready continuation helpers

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    // MARK: - WebSocket URL construction

    private static func makeWebsocketURL(temporaryToken: String) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "ElevenLabs Scribe websocket URL is invalid."
            )
        }

        websocketURLComponents.queryItems = [
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "token", value: temporaryToken),
        ]

        guard let websocketURL = websocketURLComponents.url else {
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "ElevenLabs Scribe websocket URL could not be created."
            )
        }

        return websocketURL
    }
}
