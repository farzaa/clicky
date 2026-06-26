//
//  OpenAIRealtimeVoiceClient.swift
//  leanring-buddy
//
//  Spider's OpenAI Realtime speech boundary.
//

import AVFoundation
import Foundation

struct OpenAIRealtimeClientSecret: Decodable, Equatable {
    private static let maxAuthorizedSecretCharacters = 4_096
    private static let authorizedSecretPattern = #"^[!-~]+$"#
    private static let maxAuthorizedModelCharacters = 128
    private static let authorizedModelNamePattern = #"^[A-Za-z0-9._-]+$"#

    let value: String
    let expiresAt: Int?
    let model: String

    private enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
        case clientSecret = "client_secret"
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedModel = try container.decode(String.self, forKey: .model)
        self.model = try Self.validatedAuthorizedModelName(decodedModel)

        if let decodedValue = try container.decodeIfPresent(String.self, forKey: .value) {
            self.value = try Self.validatedAuthorizedSecretValue(decodedValue)
            self.expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
            return
        }

        let nestedContainer = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .clientSecret)
        let decodedValue = try nestedContainer.decode(String.self, forKey: .value)
        self.value = try Self.validatedAuthorizedSecretValue(decodedValue)
        self.expiresAt = try nestedContainer.decodeIfPresent(Int.self, forKey: .expiresAt)
    }

    private static func validatedAuthorizedSecretValue(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= maxAuthorizedSecretCharacters,
              value.range(of: authorizedSecretPattern, options: .regularExpression) != nil else {
            throw OpenAIRealtimeClientSecretDecodingError.invalidSecretValue
        }
        return value
    }

    private static func validatedAuthorizedModelName(_ model: String) throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              trimmedModel.count <= maxAuthorizedModelCharacters,
              trimmedModel.range(of: authorizedModelNamePattern, options: .regularExpression) != nil else {
            throw OpenAIRealtimeClientSecretDecodingError.invalidModelName
        }
        return trimmedModel
    }
}

private enum OpenAIRealtimeClientSecretDecodingError: Error {
    case invalidSecretValue
    case invalidModelName
}

final class OpenAIRealtimeVoiceClient {
    private static let maxClientSecretResponseBytes = 65_536

    private let clientSecretURL: URL
    private let session: URLSession
    private let tokenProvider: () -> String?
    private var activeSpeechSession: OpenAIRealtimeSpeechSession?

    init(
        clientSecretURL: URL = SpiderConfiguration.endpoint("realtime/client-secret"),
        tokenProvider: @escaping () -> String? = { SpiderConfiguration.sessionBearerToken }
    ) {
        self.clientSecretURL = clientSecretURL
        self.tokenProvider = tokenProvider

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func createClientSecret() async throws -> OpenAIRealtimeClientSecret {
        guard let token = tokenProvider().flatMap(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token) else {
            throw OpenAIRealtimeVoiceClientError.missingSessionToken
        }

        var request = URLRequest(url: clientSecretURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIRealtimeVoiceClientError.invalidWorkerResponse
        }

        guard data.count <= Self.maxClientSecretResponseBytes else {
            throw OpenAIRealtimeVoiceClientError.clientSecretResponseTooLarge
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SpiderWorkerClientError(
                statusCode: httpResponse.statusCode,
                operation: "realtime_client_secret"
            )
        }

        return try JSONDecoder().decode(OpenAIRealtimeClientSecret.self, from: data)
    }

    @MainActor
    func speak(_ text: String) async throws {
        stopActiveSpeech()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let clientSecret = try await createClientSecret()
        let speechSession = OpenAIRealtimeSpeechSession(
            clientSecret: clientSecret.value,
            model: clientSecret.model
        )
        activeSpeechSession = speechSession

        do {
            try await speechSession.speak(trimmedText)
        } catch {
            speechSession.cancel()
            if activeSpeechSession === speechSession {
                activeSpeechSession = nil
            }
            throw error
        }

        if activeSpeechSession === speechSession {
            activeSpeechSession = nil
        }
    }

    @MainActor
    func stopActiveSpeech() {
        activeSpeechSession?.cancel()
        activeSpeechSession = nil
    }
}

@MainActor
private final class OpenAIRealtimeSpeechSession {
    private static let maxServerEventTextBytes = 262_144
    private static let maxClientEventTextBytes = 262_144

    private let clientSecret: String
    private let model: String
    private let urlSession: URLSession
    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputAudioFormat: AVAudioFormat

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var hasReceivedResponseDone = false
    private var pendingAudioBufferCount = 0
    private var hasFinished = false

    init(clientSecret: String, model: String) {
        self.clientSecret = clientSecret
        self.model = model
        self.urlSession = URLSession(configuration: .ephemeral)
        self.outputAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }

    func speak(_ text: String) async throws {
        try startPlayback()
        try connect()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            Task { [weak self] in
                guard let self else { return }

                do {
                    try await self.sendJSON([
                        "type": "conversation.item.create",
                        "item": [
                            "type": "message",
                            "role": "user",
                            "content": [
                                [
                                    "type": "input_text",
                                    "text": "Read the following Spider guidance aloud exactly. Do not add any extra words:\n\n\(text)",
                                ],
                            ],
                        ],
                    ])

                    try await self.sendJSON([
                        "type": "response.create",
                        "response": [
                            "modalities": ["audio"],
                            "instructions": "Speak naturally and briefly. Do not add anything beyond the requested guidance.",
                        ],
                    ])
                } catch {
                    self.finishIfNeeded(with: error)
                }
            }
        }
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil

        Task {
            try? await sendJSON(["type": "response.cancel"])
            webSocketTask?.cancel(with: .goingAway, reason: nil)
        }

        playerNode.stop()
        playbackEngine.stop()
        finishIfNeeded(with: nil)
    }

    private func connect() throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]

        guard let url = components.url else {
            throw OpenAIRealtimeVoiceClientError.invalidRealtimeURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: request)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
    }

    private func startPlayback() throws {
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: outputAudioFormat)
        playbackEngine.prepare()
        try playbackEngine.start()
        playerNode.play()
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
                finishIfNeeded(with: error)
                return
            }
        }
    }

    private func handleServerMessageText(_ text: String) {
        guard text.utf8.count <= Self.maxServerEventTextBytes else {
            finishIfNeeded(with: OpenAIRealtimeVoiceClientError.realtimeError)
            return
        }

        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "response.output_audio.delta":
            if let base64Audio = event["delta"] as? String,
               let audioData = Data(base64Encoded: base64Audio) {
                playAudioDelta(audioData)
            }
        case "response.output_audio.done", "response.done":
            hasReceivedResponseDone = true
            finishIfPossible()
        case "error":
            finishIfNeeded(with: OpenAIRealtimeVoiceClientError.realtimeError)
        default:
            break
        }
    }

    private func playAudioDelta(_ audioData: Data) {
        guard let audioBuffer = makePCM16AudioBuffer(from: audioData) else { return }

        pendingAudioBufferCount += 1
        playerNode.scheduleBuffer(audioBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAudioBufferCount = max(0, self.pendingAudioBufferCount - 1)
                self.finishIfPossible()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func makePCM16AudioBuffer(from audioData: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(outputAudioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = AVAudioFrameCount(audioData.count / bytesPerFrame)
        guard frameCount > 0,
              let audioBuffer = AVAudioPCMBuffer(
                pcmFormat: outputAudioFormat,
                frameCapacity: frameCount
              ),
              let destination = audioBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        audioBuffer.frameLength = frameCount
        audioData.copyBytes(
            to: UnsafeMutableRawBufferPointer(start: destination, count: audioData.count)
        )
        return audioBuffer
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeVoiceClientError.webSocketNotConnected
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= Self.maxClientEventTextBytes else {
            throw OpenAIRealtimeVoiceClientError.clientEventTooLarge
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeVoiceClientError.invalidClientEvent
        }

        try await webSocketTask.send(.string(jsonString))
    }

    private func finishIfPossible() {
        guard hasReceivedResponseDone && pendingAudioBufferCount == 0 else { return }
        finishIfNeeded(with: nil)
    }

    private func finishIfNeeded(with error: Error?) {
        guard !hasFinished else { return }
        hasFinished = true

        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        playerNode.stop()
        playbackEngine.stop()

        if let error {
            finishContinuation?.resume(throwing: error)
        } else {
            finishContinuation?.resume()
        }
        finishContinuation = nil
    }
}

enum OpenAIRealtimeVoiceClientError: LocalizedError {
    case missingSessionToken
    case invalidWorkerResponse
    case invalidRealtimeURL
    case webSocketNotConnected
    case invalidClientEvent
    case clientEventTooLarge
    case clientSecretResponseTooLarge
    case realtimeError

    var errorDescription: String? {
        switch self {
        case .missingSessionToken:
            return "Spider session token is missing."
        case .invalidWorkerResponse:
            return "Worker response is invalid."
        case .invalidRealtimeURL:
            return "OpenAI Realtime URL is invalid."
        case .webSocketNotConnected:
            return "OpenAI Realtime WebSocket is not connected."
        case .invalidClientEvent:
            return "OpenAI Realtime client event could not be encoded."
        case .clientEventTooLarge:
            return "OpenAI Realtime client event was too large."
        case .clientSecretResponseTooLarge:
            return "OpenAI Realtime client secret response was too large."
        case .realtimeError:
            return "OpenAI Realtime returned an error."
        }
    }
}
