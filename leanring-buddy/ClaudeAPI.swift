//
//  ClaudeAPI.swift
//  OpenRouter API Implementation with streaming support
//

import Foundation

struct OpenRouterModel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let supportedParameters: [String]
    let architectureInputModalities: [String]
    let architectureOutputModalities: [String]
    let endpointTools: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case supportedParameters = "supported_parameters"
        case architecture
        case endpoint
    }

    enum ArchitectureCodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }

    enum EndpointCodingKeys: String, CodingKey {
        case supportedTools = "supported_tools"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        supportedParameters = (try? container.decode([String].self, forKey: .supportedParameters)) ?? []

        if let architectureContainer = try? container.nestedContainer(keyedBy: ArchitectureCodingKeys.self, forKey: .architecture) {
            architectureInputModalities = (try? architectureContainer.decode([String].self, forKey: .inputModalities)) ?? []
            architectureOutputModalities = (try? architectureContainer.decode([String].self, forKey: .outputModalities)) ?? []
        } else {
            architectureInputModalities = []
            architectureOutputModalities = []
        }

        if let endpointContainer = try? container.nestedContainer(keyedBy: EndpointCodingKeys.self, forKey: .endpoint) {
            endpointTools = (try? endpointContainer.decode([String].self, forKey: .supportedTools)) ?? []
        } else {
            endpointTools = []
        }
    }

    var isWebBrowsingCapable: Bool {
        let lowercaseModelID = id.lowercased()
        let lowercaseTools = endpointTools.map { $0.lowercased() }
        let lowercaseSupportedParameters = supportedParameters.map { $0.lowercased() }
        let lowercaseInputModalities = architectureInputModalities.map { $0.lowercased() }

        if lowercaseTools.contains(where: { $0.contains("web") || $0.contains("search") || $0.contains("browser") }) {
            return true
        }

        if lowercaseSupportedParameters.contains(where: { $0.contains("web") || $0.contains("search") || $0.contains("browser") }) {
            return true
        }

        if lowercaseInputModalities.contains(where: { $0.contains("web") }) {
            return true
        }

        // OpenRouter model IDs for web-capable models often include these tokens.
        return lowercaseModelID.contains("search")
            || lowercaseModelID.contains("online")
            || lowercaseModelID.contains("web")
            || lowercaseModelID.contains("sonar")
    }
}

/// OpenRouter API helper with streaming for progressive text display.
final class OpenRouterAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
        warmUpTLSConnectionIfNeeded()
    }

    private func makeChatRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://clicky.so", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Clicky", forHTTPHeaderField: "X-Title")
        return request
    }

    private func extractWebSearchQuery(from argumentsJSONString: String) -> String? {
        guard let data = argumentsJSONString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            return nil
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty ? nil : trimmedQuery
    }

    private func performWebSearch(query: String) async -> String {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encodedQuery)&format=json&no_html=1&skip_disambig=1") else {
            return "Web search failed because the query could not be encoded."
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Web search did not return a usable response."
            }

            var resultLines: [String] = []

            if let abstractText = json["AbstractText"] as? String,
               !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultLines.append("Summary: \(abstractText)")
            }

            if let abstractURL = json["AbstractURL"] as? String,
               !abstractURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultLines.append("Source: \(abstractURL)")
            }

            if let relatedTopics = json["RelatedTopics"] as? [[String: Any]] {
                let compactRelatedTopics: [String] = relatedTopics
                    .compactMap { topic in
                        if let text = topic["Text"] as? String, let firstURL = topic["FirstURL"] as? String {
                            return "- \(text) (\(firstURL))"
                        }
                        if let nestedTopics = topic["Topics"] as? [[String: Any]] {
                            return nestedTopics.first.flatMap { nestedTopic in
                                guard let text = nestedTopic["Text"] as? String,
                                      let firstURL = nestedTopic["FirstURL"] as? String else {
                                    return nil
                                }
                                return "- \(text) (\(firstURL))"
                            }
                        }
                        return nil
                    }
                if !compactRelatedTopics.isEmpty {
                    resultLines.append("Related:\n" + compactRelatedTopics.prefix(4).joined(separator: "\n"))
                }
            }

            if resultLines.isEmpty {
                return "No strong web result was found for query: \(query)"
            }

            return resultLines.joined(separator: "\n")
        } catch {
            return "Web search failed with error: \(error.localizedDescription)"
        }
    }

    private func maybeAugmentMessagesWithWebSearch(
        apiKey: String,
        selectedModel: String,
        systemPrompt: String,
        messages: [[String: Any]]
    ) async -> [[String: Any]] {
        var toolRequest = makeChatRequest(apiKey: apiKey)
        let toolDefinition: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current, factual information and return concise source-backed notes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "The search query."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]

        let body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": 512,
            "stream": false,
            "messages": [["role": "system", "content": systemPrompt]] + messages,
            "tools": [toolDefinition],
            "tool_choice": "auto"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return messages
        }
        toolRequest.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: toolRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let assistantMessage = firstChoice["message"] as? [String: Any],
                  let toolCalls = assistantMessage["tool_calls"] as? [[String: Any]],
                  !toolCalls.isEmpty else {
                return messages
            }

            var augmentedMessages = messages
            augmentedMessages.append(assistantMessage)

            for toolCall in toolCalls {
                guard let toolCallID = toolCall["id"] as? String,
                      let functionPayload = toolCall["function"] as? [String: Any],
                      let functionName = functionPayload["name"] as? String,
                      functionName == "web_search",
                      let argumentsJSONString = functionPayload["arguments"] as? String,
                      let query = extractWebSearchQuery(from: argumentsJSONString) else {
                    continue
                }

                let toolResult = await performWebSearch(query: query)
                augmentedMessages.append([
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "content": toolResult
                ])
            }

            return augmentedMessages
        } catch {
            return messages
        }
    }

    private func shouldUseFallbackWebSearch(
        selectedModel: String,
        knownModels: [OpenRouterModel]
    ) -> Bool {
        guard let selectedOpenRouterModel = knownModels.first(where: { $0.id == selectedModel }) else {
            // If capabilities are unknown, keep fallback on to avoid losing web access.
            return true
        }
        return !selectedOpenRouterModel.isWebBrowsingCapable
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        var warmupRequest = URLRequest(url: URL(string: "https://openrouter.ai/")!)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to OpenRouter with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        apiKey: String,
        selectedModel: String,
        knownModels: [OpenRouterModel],
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        /// When true, skips the optional prefetch round that can call `web_search` before the vision stream.
        /// Use for local UI control (Computer Use) so words in the transcript (e.g. product names in tab titles)
        /// do not trigger irrelevant search results that confuse coordinate output.
        forceDisableWebSearchAugmentation: Bool = false,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeChatRequest(apiKey: apiKey)

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": [["type": "text", "text": userPlaceholder]]])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": "Screenshot label: \(image.label)"
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let shouldUseFallbackSearch = shouldUseFallbackWebSearch(
            selectedModel: selectedModel,
            knownModels: knownModels
        )

        let augmentedMessages: [[String: Any]]
        if shouldUseFallbackSearch, !forceDisableWebSearchAugmentation {
            print("🌐 OpenRouter path: fallback web_search tool enabled")
            augmentedMessages = await maybeAugmentMessagesWithWebSearch(
                apiKey: apiKey,
                selectedModel: selectedModel,
                systemPrompt: systemPrompt,
                messages: messages
            )
        } else {
            if shouldUseFallbackSearch, forceDisableWebSearchAugmentation {
                print("🌐 OpenRouter path: web_search augmentation skipped (local UI / computer control)")
            } else if !shouldUseFallbackSearch {
                print("🌐 OpenRouter path: native model browsing preferred")
            }
            augmentedMessages = messages
        }

        let body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": 1024,
            "stream": true,
            "messages": [["role": "system", "content": systemPrompt]] + augmentedMessages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenRouter streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenRouterAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "OpenRouterAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream from OpenAI-compatible chunks.
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String else {
                continue
            }
            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    func fetchModels(apiKey: String) async throws -> [OpenRouterModel] {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://clicky.so", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Clicky", forHTTPHeaderField: "X-Title")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenRouterAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Model list error: \(responseString)"])
        }

        struct OpenRouterModelListResponse: Decodable {
            let data: [OpenRouterModel]
        }
        let decodedResponse = try JSONDecoder().decode(OpenRouterModelListResponse.self, from: data)
        return decodedResponse.data.sorted { leftModel, rightModel in
            leftModel.id.localizedCaseInsensitiveCompare(rightModel.id) == .orderedAscending
        }
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        apiKey: String,
        selectedModel: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeChatRequest(apiKey: apiKey)

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": [["type": "text", "text": userPlaceholder]]])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": "Screenshot label: \(image.label)"
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": 256,
            "messages": [["role": "system", "content": systemPrompt]] + messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenRouter request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenRouterAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "OpenRouterAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
