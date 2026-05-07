//
//  DeepgramAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  AI transcription provider backed by the local proxy's Deepgram Listen route.
//

import AVFoundation
import Foundation

struct DeepgramAudioTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class DeepgramAudioTranscriptionProvider: BuddyTranscriptionProvider {
    private static let transcriptionProxyURL = URL(string: "http://127.0.0.1:8877/transcribe")!

    let displayName = "Deepgram"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping @Sendable (String) -> Void,
        onFinalTranscriptReady: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        DeepgramAudioTranscriptionSession(
            transcriptionURL: Self.transcriptionProxyURL,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class DeepgramAudioTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private struct DeepgramResponse: Decodable {
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable {
                    let transcript: String?
                }

                let alternatives: [Alternative]
            }

            let channels: [Channel]
        }

        let results: Results?
    }

    private static let targetSampleRate = 16_000

    private let transcriptionURL: URL
    private let keyterms: [String]
    private let onTranscriptUpdate: @Sendable (String) -> Void
    private let onFinalTranscriptReady: @Sendable (String) -> Void
    private let onError: @Sendable (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.deepgram.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        transcriptionURL: URL,
        keyterms: [String],
        onTranscriptUpdate: @escaping @Sendable (String) -> Void,
        onFinalTranscriptReady: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.transcriptionURL = transcriptionURL
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 45
        urlSessionConfiguration.timeoutIntervalForResource = 90
        urlSessionConfiguration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let trimmedAudioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if trimmedAudioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Deepgram Transcription] ❌ Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contextualPrompt = transcriptionPromptText() {
            request.setValue(contextualPrompt, forHTTPHeaderField: "X-Clicky-Keyterms")
        }
        request.httpBody = wavAudioData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramAudioTranscriptionProviderError(
                message: "Deepgram transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw DeepgramAudioTranscriptionProviderError(
                message: "Deepgram transcription failed: \(responseText)"
            )
        }

        let transcriptText = try parseTranscript(from: responseData)
        if !transcriptText.isEmpty {
            return transcriptText
        }

        throw DeepgramAudioTranscriptionProviderError(
            message: "Deepgram transcription returned an empty transcript."
        )
    }

    private func parseTranscript(from responseData: Data) throws -> String {
        if let deepgramResponse = try? JSONDecoder().decode(DeepgramResponse.self, from: responseData) {
            let transcripts = deepgramResponse.results?.channels
                .flatMap(\.alternatives)
                .compactMap(\.transcript)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return transcripts.joined(separator: " ")
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !responseText.isEmpty {
            return responseText
        }

        throw DeepgramAudioTranscriptionProviderError(
            message: "Deepgram transcription response could not be parsed."
        )
    }

    private func transcriptionPromptText() -> String? {
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedKeyterms.isEmpty else { return nil }
        return normalizedKeyterms.joined(separator: ", ")
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        // Do not call cancel() here: cancel() schedules an async stateQueue block that
        // captures self. If the session is already deinitializing on/near that queue,
        // Swift detects the object being resurrected during deinit and aborts with:
        // "deallocated with non-zero retain count".
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}
