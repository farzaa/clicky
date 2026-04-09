//
//  LMStudioLocalChatClient.swift
//  leanring-buddy
//
//  Local companion backend that talks directly to an LM Studio server running
//  on the same machine. Uses any currently loaded LLM from LM Studio.
//

import Foundation

enum LMStudioLocalChatClientError: LocalizedError {
    case invalidServerURL
    case serverUnavailable(message: String)
    case invalidModelsResponse
    case noModelLoaded
    case apiError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid LM Studio server URL."
        case .serverUnavailable(let message):
            return message
        case .invalidModelsResponse:
            return "LM Studio responded, but Clicky could not read the model list."
        case .noModelLoaded:
            return "LM Studio is running, but no model is loaded."
        case .apiError(let message):
            return message
        }
    }
}

private struct LMStudioResolvedModel {
    let identifier: String
    let displayName: String
}

private struct LMStudioModelsResponse: Decodable {
    let models: [LMStudioModel]
}

private struct LMStudioModel: Decodable {
    let type: String
    let key: String
    let displayName: String
    let loadedInstances: [LMStudioLoadedInstance]

    private enum CodingKeys: String, CodingKey {
        case type
        case key
        case displayName = "display_name"
        case loadedInstances = "loaded_instances"
    }
}

private struct LMStudioLoadedInstance: Decodable {
    let id: String
}

final class LMStudioLocalChatClient: CompanionChatClient {
    static let defaultServerBaseURLString = "http://localhost:1234"

    private let stateLock = NSLock()
    private let session: URLSession
    private var serverBaseURLString = LMStudioLocalChatClient.defaultServerBaseURLString
    private var connectedModelDisplayNameStorage: String?

    var connectedModelDisplayName: String? {
        stateLock.withLock {
            connectedModelDisplayNameStorage
        }
    }

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func updateServerBaseURLString(_ serverBaseURLString: String) {
        let trimmedServerBaseURLString = serverBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        stateLock.withLock {
            self.serverBaseURLString = trimmedServerBaseURLString.isEmpty
                ? Self.defaultServerBaseURLString
                : trimmedServerBaseURLString
            connectedModelDisplayNameStorage = nil
        }
    }

    func prepareSelectedModel(
        progressHandler: @MainActor @escaping (Progress?) -> Void
    ) async throws {
        await MainActor.run {
            progressHandler(nil)
        }

        let resolvedModel = try await resolveLoadedModel()

        stateLock.withLock {
            connectedModelDisplayNameStorage = resolvedModel.displayName
        }
    }

    func offloadResources() {
        stateLock.withLock {
            connectedModelDisplayNameStorage = nil
        }
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        progressHandler: @MainActor @escaping (Progress?) -> Void,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        await MainActor.run {
            progressHandler(nil)
        }

        let resolvedModel = try await resolveLoadedModel()
        let requestURL = try makeRequestURL(path: "/v1/chat/completions")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = try buildChatRequestBody(
            modelIdentifier: resolvedModel.identifier,
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        request.httpBody = requestBody
        let payloadMB = Double(requestBody.count) / 1_048_576.0
        print("🖥️ LM Studio request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let startTime = Date()
        let byteStream: URLSession.AsyncBytes
        let response: URLResponse

        do {
            (byteStream, response) = try await session.bytes(for: request)
        } catch {
            throw mapTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioLocalChatClientError.apiError(message: "LM Studio returned an invalid HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            let errorBody = errorBodyLines.joined(separator: "\n")
            throw LMStudioLocalChatClientError.apiError(
                message: "LM Studio API error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data:") else { continue }

            let jsonString: String
            if line.hasPrefix("data: ") {
                jsonString = String(line.dropFirst(6))
            } else {
                jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }

            guard jsonString != "[DONE]" else { break }
            guard let jsonData = jsonString.data(using: .utf8) else { continue }
            guard let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            let textChunk = extractStreamText(from: eventPayload)
            guard !textChunk.isEmpty else { continue }

            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (
            text: accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: duration
        )
    }

    private func resolveLoadedModel() async throws -> LMStudioResolvedModel {
        let requestURL = try makeRequestURL(path: "/api/v1/models")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let responseData: Data
        let response: URLResponse

        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioLocalChatClientError.apiError(message: "LM Studio returned an invalid HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw LMStudioLocalChatClientError.apiError(
                message: "LM Studio model list error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        let modelsResponse: LMStudioModelsResponse
        do {
            modelsResponse = try JSONDecoder().decode(LMStudioModelsResponse.self, from: responseData)
        } catch {
            throw LMStudioLocalChatClientError.invalidModelsResponse
        }

        let loadedLanguageModels = modelsResponse.models.filter { model in
            model.type == "llm" && !model.loadedInstances.isEmpty
        }

        guard !loadedLanguageModels.isEmpty else {
            throw LMStudioLocalChatClientError.noModelLoaded
        }

        guard let selectedLoadedModel = loadedLanguageModels.first,
              let selectedLoadedInstance = selectedLoadedModel.loadedInstances.first else {
            throw LMStudioLocalChatClientError.noModelLoaded
        }

        let resolvedModel = LMStudioResolvedModel(
            identifier: selectedLoadedInstance.id,
            displayName: selectedLoadedModel.displayName
        )

        stateLock.withLock {
            connectedModelDisplayNameStorage = resolvedModel.displayName
        }

        return resolvedModel
    }

    private func buildChatRequestBody(
        modelIdentifier: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> Data {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ]
        ]

        for historyEntry in conversationHistory {
            messages.append([
                "role": "user",
                "content": historyEntry.userPlaceholder
            ])
            messages.append([
                "role": "assistant",
                "content": historyEntry.assistantResponse
            ])
        }

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": buildCurrentUserPrompt(images: images, userPrompt: userPrompt)
            ]
        ]

        for image in images {
            let imageMediaType = detectImageMediaType(for: image.data)
            userContent.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(imageMediaType);base64,\(image.data.base64EncodedString())"
                ]
            ])
        }

        messages.append([
            "role": "user",
            "content": userContent
        ])

        let body: [String: Any] = [
            "model": modelIdentifier,
            "stream": true,
            "max_tokens": 1024,
            "messages": messages
        ]

        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildCurrentUserPrompt(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> String {
        let orderedImageLabels = images.map(\.label).joined(separator: "\n")

        guard !orderedImageLabels.isEmpty else {
            return userPrompt
        }

        return """
        attached image labels, in the same order as the screenshots:
        \(orderedImageLabels)

        \(userPrompt)
        """
    }

    private func makeRequestURL(path: String) throws -> URL {
        let currentServerBaseURLString = stateLock.withLock {
            serverBaseURLString
        }

        guard var components = URLComponents(string: currentServerBaseURLString) else {
            throw LMStudioLocalChatClientError.invalidServerURL
        }

        if components.scheme == nil {
            components.scheme = "http"
        }

        if components.host == nil,
           let pathWithoutLeadingSlashes = components.path.split(separator: "/").first,
           !pathWithoutLeadingSlashes.isEmpty {
            components.host = String(pathWithoutLeadingSlashes)
            components.path = ""
        }

        guard components.host != nil else {
            throw LMStudioLocalChatClientError.invalidServerURL
        }

        components.path = path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw LMStudioLocalChatClientError.invalidServerURL
        }

        return url
    }

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

    private func extractStreamText(from eventPayload: [String: Any]) -> String {
        guard let choices = eventPayload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return ""
        }

        if let textChunk = delta["content"] as? String {
            return textChunk
        }

        if let contentBlocks = delta["content"] as? [[String: Any]] {
            return contentBlocks.compactMap { block in
                block["text"] as? String
            }.joined()
        }

        return ""
    }

    private func mapTransportError(_ error: Error) -> LMStudioLocalChatClientError {
        let errorDescription = (error as NSError).localizedDescription
        return LMStudioLocalChatClientError.serverUnavailable(
            message: "Could not reach LM Studio at \(stateLock.withLock { serverBaseURLString }). \(errorDescription)"
        )
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
