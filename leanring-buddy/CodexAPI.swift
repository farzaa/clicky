//
//  CodexAPI.swift
//  OpenAI Codex Responses API implementation with streaming support
//

import Foundation

/// OpenAI Codex helper with streaming for progressive text display.
class CodexAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gpt-5.2-codex") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // carrying screenshot data doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored because this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter; the TLS handshake is the goal.
        }.resume()
    }

    /// Send a vision request to the Codex model with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        let body = makeResponsesRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 1024,
            stream: true
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Codex streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CodexAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "CodexAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            if eventType == "response.output_text.delta",
               let textChunk = eventPayload["delta"] as? String {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            } else if eventType == "response.output_text.done",
                      accumulatedResponseText.isEmpty,
                      let completedText = eventPayload["text"] as? String {
                accumulatedResponseText = completedText
                await onTextChunk(completedText)
            } else if eventType == "error" {
                let message = Self.extractErrorMessage(from: eventPayload)
                throw NSError(
                    domain: "CodexAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        let body = makeResponsesRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 256,
            stream: false
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Codex request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "CodexAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = Self.extractResponseText(from: json) else {
            throw NSError(
                domain: "CodexAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    private func makeResponsesRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        maxOutputTokens: Int,
        stream: Bool
    ) -> [String: Any] {
        var contentBlocks: [[String: Any]] = []

        for image in images {
            contentBlocks.append([
                "type": "input_text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"
            ])
        }

        contentBlocks.append([
            "type": "input_text",
            "text": makePromptText(
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        ])

        return [
            "model": model,
            "instructions": systemPrompt,
            "input": [
                [
                    "role": "user",
                    "content": contentBlocks
                ]
            ],
            "max_output_tokens": maxOutputTokens,
            "store": false,
            "stream": stream
        ]
    }

    private func makePromptText(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        guard !conversationHistory.isEmpty else {
            return userPrompt
        }

        let recentConversationText = conversationHistory
            .map { entry in
                "User: \(entry.userPlaceholder)\nAssistant: \(entry.assistantResponse)"
            }
            .joined(separator: "\n\n")

        return """
        Recent conversation context:
        \(recentConversationText)

        Current user request:
        \(userPrompt)
        """
    }

    private static func extractResponseText(from json: [String: Any]?) -> String? {
        if let outputText = json?["output_text"] as? String {
            return outputText
        }

        guard let outputItems = json?["output"] as? [[String: Any]] else {
            return nil
        }

        var textParts: [String] = []
        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in contentItems {
                if let text = contentItem["text"] as? String,
                   (contentItem["type"] as? String) == "output_text" {
                    textParts.append(text)
                }
            }
        }

        return textParts.isEmpty ? nil : textParts.joined()
    }

    private static func extractErrorMessage(from eventPayload: [String: Any]) -> String {
        if let message = eventPayload["message"] as? String {
            return message
        }

        if let error = eventPayload["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return "Codex streaming error"
    }
}
