//
//  GeminiAPI.swift
//  leanring-buddy
//
//  Gemini vision API client with SSE streaming. Matches the same interface
//  as ClaudeAPI so CompanionManager can swap between them with minimal changes.
//

import Foundation

class GeminiAPI {
    private let proxyURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gemini-2.5-flash") {
        self.proxyURL = URL(string: proxyURL)!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    private func detectImageMimeType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Sends a vision request to Gemini with SSE streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        // Build Gemini's `contents` array from conversation history + current turn.
        // Gemini uses a different schema than Claude: each turn has a `role` and
        // `parts` array. System instructions are passed separately.
        var contents: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            contents.append([
                "role": "user",
                "parts": [["text": userPlaceholder]]
            ])
            contents.append([
                "role": "model",
                "parts": [["text": assistantResponse]]
            ])
        }

        // Build the current user turn with images + labels + prompt
        var currentTurnParts: [[String: Any]] = []
        for image in images {
            currentTurnParts.append([
                "inline_data": [
                    "mime_type": detectImageMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentTurnParts.append(["text": image.label])
        }
        currentTurnParts.append(["text": userPrompt])

        contents.append([
            "role": "user",
            "parts": currentTurnParts
        ])

        let geminiRequest: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 1024,
                "temperature": 1.0
            ]
        ]

        // Wrap in our proxy envelope so the worker knows which model to use
        let proxyEnvelope: [String: Any] = [
            "model": model,
            "geminiRequest": geminiRequest
        ]

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyData = try JSONSerialization.data(withJSONObject: proxyEnvelope)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Gemini streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GeminiAPI",
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
                domain: "GeminiAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse Gemini's SSE stream. Each event is "data: {json}\n\n".
        // The text lives at: candidates[0].content.parts[0].text
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let candidates = eventPayload["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let textChunk = parts.first?["text"] as? String else {
                continue
            }

            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }
}
