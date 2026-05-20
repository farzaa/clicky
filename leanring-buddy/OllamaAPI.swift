//
//  OllamaAPI.swift
//  leanring-buddy
//
//  AI vision and chat client backed by a local Ollama server.
//  Talks to the OpenAI-compatible endpoint at http://localhost:11434/v1/chat/completions
//  so no API keys, no external network, and no Cloudflare Worker are needed.
//
//  nemotron3 (and other reasoning models) emit internal "reasoning" tokens before
//  producing visible output. Those chunks have an empty "content" field and a
//  non-empty "reasoning" field. We silently skip them so only real response text
//  reaches the UI and TTS pipeline.
//

import Foundation

class OllamaAPI {
    /// Base URL of the local Ollama server. Change this if Ollama is bound to a
    /// different address (e.g. another machine on the LAN).
    private static let ollamaBaseURL = "http://localhost:11434"
    private static let chatEndpointPath = "/v1/chat/completions"

    var model: String

    private let chatEndpointURL: URL
    private let session: URLSession

    init(model: String = "nemotron3:33b") {
        self.model = model
        self.chatEndpointURL = URL(string: Self.ollamaBaseURL + Self.chatEndpointPath)!

        // Plain HTTP to localhost — no TLS, no cookie storage needed.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false  // Localhost should always be reachable immediately
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Image MIME Detection

    /// Inspects the first bytes of image data to detect whether it is PNG or JPEG.
    /// Screen captures from ScreenCaptureKit are JPEG; clipboard pastes may be PNG.
    /// The Ollama API rejects requests where the declared MIME type mismatches the
    /// actual image format.
    private func detectImageMIMEType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngMagicBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngMagicBytes {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    // MARK: - Request Building

    private func makeBaseRequest() -> URLRequest {
        var request = URLRequest(url: chatEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Builds the OpenAI-compatible messages array.
    ///
    /// The system prompt becomes a leading {"role":"system"} message.
    /// Conversation history is interleaved as user/assistant pairs.
    /// The current user turn contains inline base64 image content blocks followed
    /// by the text prompt — matching how the Ollama vision API expects multimodal input.
    private func buildMessagesPayload(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        // System prompt as the first message in OpenAI/Ollama format
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Prior conversation turns so the model has context from earlier exchanges
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Current user turn: images first (as image_url content blocks), then the text prompt
        var currentTurnContentBlocks: [[String: Any]] = []

        for image in images {
            let mimeType = detectImageMIMEType(for: image.data)
            let base64EncodedImageString = image.data.base64EncodedString()
            let dataURLString = "data:\(mimeType);base64,\(base64EncodedImageString)"

            // Label text block first so the model knows which screen it's looking at
            currentTurnContentBlocks.append([
                "type": "text",
                "text": image.label
            ])

            currentTurnContentBlocks.append([
                "type": "image_url",
                "image_url": ["url": dataURLString]
            ])
        }

        currentTurnContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])

        messages.append([
            "role": "user",
            "content": currentTurnContentBlocks
        ])

        return messages
    }

    // MARK: - Streaming Request

    /// Sends a vision request to the local Ollama server with SSE streaming.
    ///
    /// Calls `onTextChunk` on the main actor each time new accumulated text arrives,
    /// enabling the UI to update progressively as the model generates its response.
    /// Silently skips "reasoning" token chunks (content is empty, reasoning field is set)
    /// that reasoning models like nemotron3 emit before producing actual output.
    ///
    /// Returns the full accumulated response text and total elapsed time when streaming ends.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        var request = makeBaseRequest()

        let messagesPayload = buildMessagesPayload(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messagesPayload,
            "stream": true,
            "max_tokens": 1024
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = requestBodyData

        let payloadSizeMB = Double(requestBodyData.count) / 1_048_576.0
        print("🤖 Ollama streaming request: \(String(format: "%.1f", payloadSizeMB))MB, \(images.count) image(s), model: \(model)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Read the full error body before throwing so we can surface a useful message
            var errorBodyLines: [String] = []
            for try await errorLine in byteStream.lines {
                errorBodyLines.append(errorLine)
            }
            let errorBodyText = errorBodyLines.joined(separator: "\n")
            throw OllamaAPIError.serverError(statusCode: httpResponse.statusCode, body: errorBodyText)
        }

        var accumulatedResponseText = ""

        for try await sseDataLine in byteStream.lines {
            // SSE lines have the format:  data: {json}
            guard sseDataLine.hasPrefix("data: ") else { continue }
            let jsonPayloadString = String(sseDataLine.dropFirst(6))

            // Standard SSE stream terminator
            guard jsonPayloadString != "[DONE]" else { break }

            guard let jsonData = jsonPayloadString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choicesArray = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choicesArray.first,
                  let deltaPayload = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            // Reasoning models (like nemotron3) emit "reasoning" tokens with an empty
            // "content" field before generating the actual response. We skip those chunks
            // entirely — only accumulate when the content field has real text.
            guard let contentChunk = deltaPayload["content"] as? String,
                  !contentChunk.isEmpty else {
                continue
            }

            accumulatedResponseText += contentChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let elapsedDuration = Date().timeIntervalSince(requestStartTime)
        print("🤖 Ollama streaming complete: \(accumulatedResponseText.count) chars in \(String(format: "%.1f", elapsedDuration))s")
        return (text: accumulatedResponseText, duration: elapsedDuration)
    }

    // MARK: - Non-Streaming Request

    /// Non-streaming fallback for validation or low-latency requests where
    /// progressive display isn't needed. Waits for the full response before returning.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        var request = makeBaseRequest()

        let messagesPayload = buildMessagesPayload(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messagesPayload,
            "stream": false,
            "max_tokens": 256
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = requestBodyData

        let payloadSizeMB = Double(requestBodyData.count) / 1_048_576.0
        print("🤖 Ollama request: \(String(format: "%.1f", payloadSizeMB))MB, \(images.count) image(s), model: \(model)")

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBodyText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw OllamaAPIError.serverError(statusCode: httpResponse.statusCode, body: errorBodyText)
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choicesArray = responseJSON["choices"] as? [[String: Any]],
              let firstChoice = choicesArray.first,
              let messagePayload = firstChoice["message"] as? [String: Any],
              let responseText = messagePayload["content"] as? String else {
            throw OllamaAPIError.unexpectedResponseFormat
        }

        let elapsedDuration = Date().timeIntervalSince(requestStartTime)
        return (text: responseText, duration: elapsedDuration)
    }
}

// MARK: - Error Types

enum OllamaAPIError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, body: String)
    case unexpectedResponseFormat
    case ollamaNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Ollama returned an invalid HTTP response."
        case .serverError(let statusCode, let body):
            return "Ollama server error (\(statusCode)): \(body)"
        case .unexpectedResponseFormat:
            return "Ollama response was not in the expected format."
        case .ollamaNotRunning:
            return "Ollama server is not running. Start it with: ollama serve"
        }
    }
}
