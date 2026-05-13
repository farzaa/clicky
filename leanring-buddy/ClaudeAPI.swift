//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "claude-sonnet-4-6") {
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
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Dot inference gateway authenticates every request with the
        // user's install token. Reading it lazily here means a freshly issued
        // token (right after sign-in) is picked up without recreating clients.
        if let installToken = DotInstallTokenStore.currentInstallToken() {
            request.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        }
        return request
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

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
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
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
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

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let requestStartedAt = Date()

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
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
            let requestDurationMs = Int((Date().timeIntervalSince(requestStartedAt) * 1_000).rounded())
            DotAnalytics.trackInferenceEndpointResult(
                endpoint: "chat",
                statusCode: httpResponse.statusCode,
                durationMs: requestDurationMs,
                provider: "anthropic",
                model: model
            )
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: httpResponse.statusCode,
                responseBody: errorBody,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Result of one tool-use agent turn: any text blocks Claude wrote (to be
    /// fed to the per-step narration queue) and any tool_use blocks (to be
    /// executed). The raw assistant content blocks are also returned so the
    /// agent loop can echo them back in the next request's messages array.
    struct ToolUseTurnResponse {
        let textBlocks: [String]
        let toolUseBlocks: [AgentToolUseBlock]
        let rawAssistantContentBlocks: [[String: Any]]
        let stopReason: String?
    }

    private struct StreamingToolUseContentBlock {
        let index: Int
        var type: String
        var text: String = ""
        var toolUseID: String?
        var toolName: String?
        var inputJSONString: String = ""
    }

    /// One turn of the tool-use agent loop. Sends `messages` + `tools` to
    /// Anthropic Messages API (non-streaming), parses the response, and
    /// returns the structured result. The caller (CompanionManager's agent
    /// loop) owns the messages list and appends the assistant response +
    /// next user message (with tool_results + new screenshot) for the next
    /// call. See docs/agent-loop-tool-use-migration.md.
    func runAgentTurnWithToolUse(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> ToolUseTurnResponse {
        var request = makeAPIRequest()
        // Opt into Anthropic's context-management beta. Required to declare
        // the memory_20250818 predefined tool in `tools`. Forwarded by the
        // vibe-id proxy via its `anthropic-beta` passthrough.
        request.setValue("context-management-2025-06-27", forHTTPHeaderField: "anthropic-beta")
        // Mark system + tools as a single cacheable prefix via cache_control
        // on the last tool. Anthropic's prompt cache (~5min TTL) then lets
        // every step after the first in a turn (and turns in quick
        // succession) hit cache for the ~2KB static prefix instead of
        // paying full price. Per-step images and tool_results stay
        // uncached because they change every call.
        let systemBlocks: [[String: Any]] = [[
            "type": "text",
            "text": systemPrompt,
            "cache_control": ["type": "ephemeral"]
        ]]
        var toolsWithCacheBreakpoint = tools
        if !toolsWithCacheBreakpoint.isEmpty {
            var lastTool = toolsWithCacheBreakpoint[toolsWithCacheBreakpoint.count - 1]
            lastTool["cache_control"] = ["type": "ephemeral"]
            toolsWithCacheBreakpoint[toolsWithCacheBreakpoint.count - 1] = lastTool
        }
        var body: [String: Any] = [
            "model": model,
            // 2048 (was 1024) gives the model headroom to emit multiple
            // tool_use blocks in one response — narration + 2-3 structured
            // tool calls can exceed 1024 tokens and we'd otherwise see the
            // model implicitly truncate to a single tool per turn.
            "max_tokens": 2048,
            "system": systemBlocks,
            "messages": messages
        ]
        if !toolsWithCacheBreakpoint.isEmpty {
            body["tools"] = toolsWithCacheBreakpoint
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude tool-use request: \(String(format: "%.1f", payloadMB))MB, messages=\(messages.count), tools=\(tools.count)")
        let requestStartedAt = Date()
        DotDebugLogger.log("claude.api", "tool-use request started", metadata: [
            "payloadMB": String(format: "%.2f", payloadMB),
            "messageCount": messages.count,
            "toolCount": tools.count
        ])

        let (data, response) = try await session.data(for: request)
        let requestDurationMs = Int((Date().timeIntervalSince(requestStartedAt) * 1_000).rounded())

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: httpResponse.statusCode,
                responseBody: responseString,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(responseString)"]
            )
        }

        guard let parsedJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = parsedJSON["content"] as? [[String: Any]] else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Tool-use response had no content array"]
            )
        }

        // Surface cache stats so we can confirm the system+tools prefix is
        // actually being read from cache on subsequent steps within a turn.
        let usageStats = parsedJSON["usage"] as? [String: Any] ?? [:]
        let inputTokens = usageStats["input_tokens"] as? Int ?? 0
        let outputTokens = usageStats["output_tokens"] as? Int ?? 0
        let cacheCreationTokens = usageStats["cache_creation_input_tokens"] as? Int ?? 0
        let cacheReadTokens = usageStats["cache_read_input_tokens"] as? Int ?? 0
        DotDebugLogger.log("claude.api", "tool-use response usage", metadata: [
            "inputTokens": inputTokens,
            "outputTokens": outputTokens,
            "cacheCreationInputTokens": cacheCreationTokens,
            "cacheReadInputTokens": cacheReadTokens,
            "requestDurationMs": requestDurationMs
        ])

        var collectedTextBlocks: [String] = []
        var collectedToolUseBlocks: [AgentToolUseBlock] = []
        for block in contentArray {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let textValue = block["text"] as? String {
                    let trimmedText = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty {
                        collectedTextBlocks.append(trimmedText)
                    }
                }
            case "tool_use":
                guard let blockID = block["id"] as? String,
                      let blockName = block["name"] as? String,
                      let blockInput = block["input"] as? [String: Any] else {
                    continue
                }
                collectedToolUseBlocks.append(AgentToolUseBlock(
                    toolUseID: blockID,
                    toolName: blockName,
                    inputArguments: blockInput
                ))
            default:
                continue
            }
        }

        return ToolUseTurnResponse(
            textBlocks: collectedTextBlocks,
            toolUseBlocks: collectedToolUseBlocks,
            rawAssistantContentBlocks: contentArray,
            stopReason: parsedJSON["stop_reason"] as? String
        )
    }

    /// Streaming variant of `runAgentTurnWithToolUse`. It reconstructs the
    /// same final assistant content blocks for the agent loop, while surfacing
    /// text deltas immediately for perceived-latency wins.
    func runAgentTurnWithToolUseStreaming(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        onTextDelta: @MainActor @Sendable (_ textDelta: String, _ accumulatedText: String) -> Void,
        onToolUseStarted: @MainActor @Sendable () -> Void
    ) async throws -> ToolUseTurnResponse {
        var request = makeAPIRequest()
        request.setValue("context-management-2025-06-27", forHTTPHeaderField: "anthropic-beta")

        let systemBlocks: [[String: Any]] = [[
            "type": "text",
            "text": systemPrompt,
            "cache_control": ["type": "ephemeral"]
        ]]
        var toolsWithCacheBreakpoint = tools
        if !toolsWithCacheBreakpoint.isEmpty {
            var lastTool = toolsWithCacheBreakpoint[toolsWithCacheBreakpoint.count - 1]
            lastTool["cache_control"] = ["type": "ephemeral"]
            toolsWithCacheBreakpoint[toolsWithCacheBreakpoint.count - 1] = lastTool
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "system": systemBlocks,
            "messages": messages
        ]
        if !toolsWithCacheBreakpoint.isEmpty {
            body["tools"] = toolsWithCacheBreakpoint
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming tool-use request: \(String(format: "%.1f", payloadMB))MB, messages=\(messages.count), tools=\(tools.count)")
        let requestStartedAt = Date()
        DotDebugLogger.log("claude.api", "streaming tool-use request started", metadata: [
            "payloadMB": String(format: "%.2f", payloadMB),
            "messageCount": messages.count,
            "toolCount": tools.count
        ])

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
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
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: httpResponse.statusCode,
                responseBody: errorBody,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var contentBlocksByIndex: [Int: StreamingToolUseContentBlock] = [:]
        var accumulatedResponseText = ""
        var stopReason: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            switch eventType {
            case "message_start":
                if let message = eventPayload["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? inputTokens
                    cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? cacheCreationTokens
                    cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? cacheReadTokens
                }

            case "content_block_start":
                guard let index = eventPayload["index"] as? Int,
                      let contentBlock = eventPayload["content_block"] as? [String: Any],
                      let blockType = contentBlock["type"] as? String else {
                    continue
                }

                var block = StreamingToolUseContentBlock(index: index, type: blockType)
                if blockType == "text" {
                    block.text = contentBlock["text"] as? String ?? ""
                    if !block.text.isEmpty {
                        accumulatedResponseText += block.text
                        await onTextDelta(block.text, accumulatedResponseText)
                    }
                } else if blockType == "tool_use" {
                    block.toolUseID = contentBlock["id"] as? String
                    block.toolName = contentBlock["name"] as? String
                    await onToolUseStarted()
                }
                contentBlocksByIndex[index] = block

            case "content_block_delta":
                guard let index = eventPayload["index"] as? Int,
                      let delta = eventPayload["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else {
                    continue
                }

                var block = contentBlocksByIndex[index] ?? StreamingToolUseContentBlock(index: index, type: "text")
                if deltaType == "text_delta",
                   let textDelta = delta["text"] as? String {
                    block.type = "text"
                    block.text += textDelta
                    accumulatedResponseText += textDelta
                    contentBlocksByIndex[index] = block
                    await onTextDelta(textDelta, accumulatedResponseText)
                } else if deltaType == "input_json_delta",
                          let partialJSON = delta["partial_json"] as? String {
                    block.type = "tool_use"
                    block.inputJSONString += partialJSON
                    contentBlocksByIndex[index] = block
                }

            case "message_delta":
                if let delta = eventPayload["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                }
                if let usage = eventPayload["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            case "message_stop":
                break

            case "error":
                let errorPayload = eventPayload["error"] as? [String: Any]
                let errorMessage = errorPayload?["message"] as? String ?? "Unknown streaming Claude error"
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )

            default:
                continue
            }
        }

        let requestDurationMs = Int((Date().timeIntervalSince(requestStartedAt) * 1_000).rounded())
        DotAnalytics.trackInferenceEndpointResult(
            endpoint: "chat",
            statusCode: httpResponse.statusCode,
            durationMs: requestDurationMs,
            provider: "anthropic",
            model: model
        )
        DotDebugLogger.log("claude.api", "streaming tool-use response usage", metadata: [
            "inputTokens": inputTokens,
            "outputTokens": outputTokens,
            "cacheCreationInputTokens": cacheCreationTokens,
            "cacheReadInputTokens": cacheReadTokens,
            "requestDurationMs": requestDurationMs
        ])

        var contentArray: [[String: Any]] = []
        var collectedTextBlocks: [String] = []
        var collectedToolUseBlocks: [AgentToolUseBlock] = []

        for index in contentBlocksByIndex.keys.sorted() {
            guard let block = contentBlocksByIndex[index] else { continue }
            switch block.type {
            case "text":
                let trimmedText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { continue }
                contentArray.append([
                    "type": "text",
                    "text": block.text
                ])
                collectedTextBlocks.append(trimmedText)

            case "tool_use":
                guard let toolUseID = block.toolUseID,
                      let toolName = block.toolName else {
                    continue
                }
                let inputArguments: [String: Any]
                if block.inputJSONString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inputArguments = [:]
                } else {
                    guard let inputData = block.inputJSONString.data(using: .utf8),
                          let parsedInput = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
                        throw NSError(
                            domain: "ClaudeAPI",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Streaming tool_use input was not valid JSON for \(toolName)"]
                        )
                    }
                    inputArguments = parsedInput
                }
                contentArray.append([
                    "type": "tool_use",
                    "id": toolUseID,
                    "name": toolName,
                    "input": inputArguments
                ])
                collectedToolUseBlocks.append(AgentToolUseBlock(
                    toolUseID: toolUseID,
                    toolName: toolName,
                    inputArguments: inputArguments
                ))

            default:
                continue
            }
        }

        return ToolUseTurnResponse(
            textBlocks: collectedTextBlocks,
            toolUseBlocks: collectedToolUseBlocks,
            rawAssistantContentBlocks: contentArray,
            stopReason: stopReason
        )
    }

    /// Summarize a chunk of past conversation via Haiku 4.5 for cheap,
    /// fast compaction of the cross-turn `conversationHistory` buffer when
    /// it grows beyond its soft cap. The returned text replaces N old
    /// exchanges with a single synthetic entry, keeping the long-term
    /// thread coherent without unbounded token growth.
    func summarizeConversationViaHaiku(transcriptToSummarize: String) async throws -> String {
        var request = makeAPIRequest()

        let summarizationSystemPrompt = """
        you summarize past conversations between dot (a macOS voice assistant) and its user. given a chunk of older exchanges, write ONE tight paragraph (3-6 sentences) capturing: recurring topics, decisions made, personal facts about the user, and any unresolved threads. omit small-talk and one-off utility commands ("open spotify"). write in third person about both parties. plain prose, no bullets, no headers.
        """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 512,
            "system": summarizationSystemPrompt,
            "messages": [[
                "role": "user",
                "content": transcriptToSummarize
            ]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseBodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                responseBody: responseBodyText,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Haiku summarize failed: \(responseBodyText)"]
            )
        }
        let parsedJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let contentArray = parsedJSON?["content"] as? [[String: Any]],
              let firstTextBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
              let summaryText = firstTextBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Haiku summarize returned no text block"]
            )
        }
        return summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read-only Haiku 4.5 review of the current /memories/ contents.
    /// Used by the sleep-cycle hygiene pass to surface duplicates,
    /// contradictions, and stale-looking entries to the user. Returns
    /// either a short observation paragraph or the literal string
    /// "nothing notable" when memory looks healthy — the caller skips
    /// surfacing in that case so the user isn't pestered for no reason.
    /// We intentionally do NOT auto-mutate memory based on this output;
    /// surfacing for human review only.
    func reviewMemoryStateViaHaiku(memoryStateText: String) async throws -> String {
        var request = makeAPIRequest()

        let memoryReviewSystemPrompt = """
        you review a snapshot of dot's long-term memory store and surface anything the USER would want to know about. each memory file is delimited by --- /memories/path ---.

        look for: (a) duplicates — multiple files saying the same fact, (b) contradictions — facts that conflict (e.g. one file says "uses cursor", another says "uses zed"), (c) stale-looking entries — facts that read like they're from an outdated context, (d) clutter — many tiny single-fact files that could be merged.

        respond with ONE short paragraph (2-4 sentences) describing what you noticed. if memory looks clean, respond with exactly "nothing notable" and nothing else. plain prose, no bullets, no headers, no preamble like "here's what i found:".
        """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 300,
            "system": memoryReviewSystemPrompt,
            "messages": [[
                "role": "user",
                "content": memoryStateText
            ]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseBodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                responseBody: responseBodyText,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Haiku memory-review failed: \(responseBodyText)"]
            )
        }
        let parsedJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let contentArray = parsedJSON?["content"] as? [[String: Any]],
              let firstTextBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
              let observationText = firstTextBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Haiku memory-review returned no text block"]
            )
        }
        return observationText.trimmingCharacters(in: .whitespacesAndNewlines)
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

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let insufficientCreditsError = VibeIdUserFacingError.insufficientCreditsErrorIfApplicable(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                responseBody: responseString,
                fallbackEndpoint: "chat"
            ) {
                throw insufficientCreditsError
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
