//
//  OpenAIResponsesAPI.swift
//  leanring-buddy
//
//  OpenAI Responses API client using a Sign in with ChatGPT access token.
//

import Foundation

struct OpenAIModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct OpenAIResponsesAPIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class OpenAIResponsesAPI {
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    private let authenticationManager: ChatGPTAuthenticationManager
    private let session: URLSession

    init(authenticationManager: ChatGPTAuthenticationManager) {
        self.authenticationManager = authenticationManager
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func listAvailableModels() async throws -> [OpenAIModelOption] {
        let accessToken = try await authenticationManager.validAccessToken()
        var request = URLRequest(url: Self.modelsURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw apiError(data: data, response: response)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIResponsesAPIError(message: "OpenAI returned an invalid model list.")
        }

        if let models = payload["models"] as? [[String: Any]] {
            return models.compactMap { model in
                guard model["visibility"] as? String == "list",
                      let slug = model["slug"] as? String else { return nil }
                let displayName = model["display_name"] as? String ?? slug
                return OpenAIModelOption(id: slug, displayName: displayName)
            }
        }

        if let models = payload["data"] as? [[String: Any]] {
            return models.compactMap { model in
                guard let modelID = model["id"] as? String else { return nil }
                return OpenAIModelOption(id: modelID, displayName: modelID)
            }
        }

        throw OpenAIResponsesAPIError(message: "OpenAI returned an invalid model list.")
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let accessToken = try await authenticationManager.validAccessToken()
        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input: [[String: Any]] = []
        for historyEntry in conversationHistory {
            input.append([
                "role": "user",
                "content": [["type": "input_text", "text": historyEntry.userPlaceholder]]
            ])
            input.append([
                "role": "assistant",
                "content": [["type": "output_text", "text": historyEntry.assistantResponse]]
            ])
        }

        var currentContent: [[String: Any]] = []
        for image in images {
            currentContent.append(["type": "input_text", "text": image.label])
            currentContent.append([
                "type": "input_image",
                "image_url": "data:\(mediaType(for: image.data));base64,\(image.data.base64EncodedString())"
            ])
        }
        currentContent.append(["type": "input_text", "text": userPrompt])
        input.append(["role": "user", "content": currentContent])

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": systemPrompt,
            "input": input,
            "store": false,
            "stream": true
        ])

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIResponsesAPIError(message: "OpenAI returned an invalid response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var responseLines: [String] = []
            for try await line in byteStream.lines { responseLines.append(line) }
            throw OpenAIResponsesAPIError(
                message: "OpenAI request failed (\(httpResponse.statusCode)): \(responseLines.joined(separator: "\n"))"
            )
        }

        var accumulatedResponseText = ""
        var didComplete = false
        for try await line in byteStream.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let eventJSON = String(line.dropFirst(6))
            guard eventJSON != "[DONE]",
                  let eventData = eventJSON.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    accumulatedResponseText += delta
                    await onTextChunk(accumulatedResponseText)
                }
            case "response.completed":
                didComplete = true
            case "response.failed", "response.incomplete":
                throw OpenAIResponsesAPIError(message: responseFailureMessage(from: event))
            default:
                break
            }
        }

        guard didComplete else {
            throw OpenAIResponsesAPIError(message: "The OpenAI response ended before completion.")
        }
        return (accumulatedResponseText, Date().timeIntervalSince(startTime))
    }

    private func mediaType(for data: Data) -> String {
        Array(data.prefix(4)) == [0x89, 0x50, 0x4e, 0x47] ? "image/png" : "image/jpeg"
    }

    private func apiError(data: Data, response: URLResponse) -> Error {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "Unknown error"
        return OpenAIResponsesAPIError(message: "OpenAI request failed (\(statusCode)): \(body)")
    }

    private func responseFailureMessage(from event: [String: Any]) -> String {
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return "OpenAI could not complete the response."
    }
}
