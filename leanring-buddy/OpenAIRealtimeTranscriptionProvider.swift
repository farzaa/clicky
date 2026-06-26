//
//  OpenAIRealtimeTranscriptionProvider.swift
//  leanring-buddy
//
//  Push-to-talk transcription through OpenAI Realtime. The app receives an
//  ephemeral Realtime client secret from the Worker; no OpenAI API key ships
//  in the macOS bundle.
//

import AVFoundation
import Foundation

enum OpenAIRealtimeTranscriptionProviderError: LocalizedError {
    case invalidRealtimeURL
    case serverEventTooLarge
    case transcriptTooLarge
    case realtimeReturnedError
    case webSocketNotConnected
    case invalidClientEvent
    case clientEventTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidRealtimeURL:
            return "OpenAI Realtime URL is invalid."
        case .serverEventTooLarge:
            return "OpenAI Realtime transcription event was too large."
        case .transcriptTooLarge:
            return "OpenAI Realtime transcription was too large."
        case .realtimeReturnedError:
            return "OpenAI Realtime transcription returned an error."
        case .webSocketNotConnected:
            return "OpenAI Realtime WebSocket is not connected."
        case .invalidClientEvent:
            return "OpenAI Realtime event could not be encoded."
        case .clientEventTooLarge:
            return "OpenAI Realtime client event was too large."
        }
    }
}

final class OpenAIRealtimeTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "OpenAI Realtime"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private let realtimeVoiceClient = OpenAIRealtimeVoiceClient()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let clientSecret = try await realtimeVoiceClient.createClientSecret()
        let session = OpenAIRealtimeTranscriptionSession(
            clientSecret: clientSecret.value,
            model: clientSecret.model,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }
}

private final class OpenAIRealtimeTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0
    private static let maxServerEventTextBytes = 262_144
    private static let maxClientEventTextBytes = 262_144
    private static let maxTranscriptCharacters = 12_000
    private static let maxKeytermCount = 24
    private static let maxSingleKeytermCharacters = 64
    private static let maxKeytermsPromptCharacters = 1_024

    private let clientSecret: String
    private let model: String
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let urlSession = URLSession(configuration: .ephemeral)
    private let sendQueue = DispatchQueue(label: "com.spider.realtime.transcription.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var latestTranscriptText = ""

    init(
        clientSecret: String,
        model: String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.clientSecret = clientSecret
        self.model = model
        self.keyterms = Self.sanitizedKeyterms(keyterms)
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]

        guard let url = components.url else {
            throw OpenAIRealtimeTranscriptionProviderError.invalidRealtimeURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: request)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "instructions": "You transcribe the user's push-to-talk request for Spider. Return only the user's words. Preserve app/product terms when possible.",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000,
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe",
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                        ],
                    ],
                ],
            ],
        ])
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }

        sendQueue.async { [weak self] in
            guard let self,
                  let audioPCM16Data = self.audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
                  !audioPCM16Data.isEmpty else {
                return
            }

            let base64Audio = audioPCM16Data.base64EncodedString()
            Task { [weak self] in
                do {
                    try await self?.sendJSON([
                        "type": "input_audio_buffer.append",
                        "audio": base64Audio,
                    ])
                } catch {
                    await self?.reportError(error)
                }
            }
        }
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true

        Task { [weak self] in
            guard let self else { return }

            do {
                try await sendJSON(["type": "input_audio_buffer.commit"])
                try await sendJSON([
                    "type": "response.create",
                    "response": [
                        "modalities": ["text"],
                        "instructions": makeFinalTranscriptionInstructions(),
                    ],
                ])
            } catch {
                if !latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deliverFinalTranscriptIfNeeded(latestTranscriptText)
                } else {
                    onError(error)
                }
            }
        }
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil

        Task { [weak self] in
            try? await self?.sendJSON(["type": "response.cancel"])
            self?.webSocketTask?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text):
                    handleServerMessageText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleServerMessageText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                if hasRequestedFinalTranscript,
                   !latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deliverFinalTranscriptIfNeeded(latestTranscriptText)
                } else {
                    onError(error)
                }
                return
            }
        }
    }

    private func handleServerMessageText(_ text: String) {
        guard text.utf8.count <= Self.maxServerEventTextBytes else {
            onError(OpenAIRealtimeTranscriptionProviderError.serverEventTooLarge)
            return
        }

        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String {
                updateTranscript(transcript)
                deliverFinalTranscriptIfNeeded(transcript)
            }
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                updateTranscript(latestTranscriptText + delta)
            }
        case "response.output_text.done":
            if let text = event["text"] as? String {
                updateTranscript(text)
                deliverFinalTranscriptIfNeeded(text)
            }
        case "response.done":
            if hasRequestedFinalTranscript,
               !latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deliverFinalTranscriptIfNeeded(latestTranscriptText)
            }
        case "error":
            onError(OpenAIRealtimeTranscriptionProviderError.realtimeReturnedError)
        default:
            break
        }
    }

    private func updateTranscript(_ transcriptText: String) {
        let trimmedTranscriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscriptText.isEmpty else { return }
        guard trimmedTranscriptText.count <= Self.maxTranscriptCharacters else {
            onError(OpenAIRealtimeTranscriptionProviderError.transcriptTooLarge)
            return
        }

        latestTranscriptText = trimmedTranscriptText
        onTranscriptUpdate(trimmedTranscriptText)
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }

        let trimmedTranscriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscriptText.isEmpty else { return }
        guard trimmedTranscriptText.count <= Self.maxTranscriptCharacters else {
            onError(OpenAIRealtimeTranscriptionProviderError.transcriptTooLarge)
            return
        }

        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(trimmedTranscriptText)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }

    private func reportError(_ error: Error) {
        onError(error)
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeTranscriptionProviderError.webSocketNotConnected
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= Self.maxClientEventTextBytes else {
            throw OpenAIRealtimeTranscriptionProviderError.clientEventTooLarge
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeTranscriptionProviderError.invalidClientEvent
        }

        try await webSocketTask.send(.string(jsonString))
    }

    private func makeFinalTranscriptionInstructions() -> String {
        let keytermsText = keyterms.isEmpty ? "" : "\nLikely terms: \(keyterms.joined(separator: ", "))."
        return """
        Transcribe the user's audio exactly enough for Spider to understand the request.
        Return only the transcription text. No commentary, no formatting, no quotes.\(keytermsText)
        """
    }

    private static func sanitizedKeyterms(_ keyterms: [String]) -> [String] {
        var promptCharacterCount = 0
        var sanitizedTerms: [String] = []

        for keyterm in keyterms.prefix(maxKeytermCount) {
            let cleanedTerm = keyterm
                .unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .map(String.init)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedTerm.isEmpty else { continue }

            let boundedTerm = String(cleanedTerm.prefix(maxSingleKeytermCharacters))
            let nextPromptCharacterCount = promptCharacterCount + boundedTerm.count
            guard nextPromptCharacterCount <= maxKeytermsPromptCharacters else { break }

            sanitizedTerms.append(boundedTerm)
            promptCharacterCount = nextPromptCharacterCount
        }

        return sanitizedTerms
    }
}
