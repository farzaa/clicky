//
//  AnthropicProvider.swift
//  yardtalk
//
//  Cloud synthesis via Anthropic's Claude API. BYOK — the user supplies
//  their own key in Settings; it's stored in the macOS Keychain and
//  travels only as the `x-api-key` header on synthesis requests.
//
//  This is the only provider that leaves the device, so it's offered as
//  an opt-in alongside Apple on-device and Ollama. Picked when the user
//  wants frontier-model quality for hard sessions where local models
//  hallucinate or paraphrase too much.
//

import Foundation
import OSLog

extension Logger {
    static let anthropic = Logger(subsystem: "com.yardtalk.app", category: "anthropic")
}

final class AnthropicProvider: SynthesisProvider {
    static let defaultBaseURLString = "https://api.anthropic.com/v1/messages"
    static let defaultModel = "claude-sonnet-4-6"

    let kind: SynthesisProviderKind = .anthropic
    let displayName: String

    private let apiURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = defaultModel) {
        self.apiKey = apiKey
        self.model = model
        self.apiURL = URL(string: Self.defaultBaseURLString)!
        self.displayName = "Claude · \(model)"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    func synthesizeStructured(
        systemPrompt: String,
        userPrompt: String,
        toolName: String,
        toolDescription: String,
        toolInputSchema: [String: Any],
        maxTokens: Int
    ) async throws -> (input: [String: Any], duration: TimeInterval) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Force a single tool_use block matching toolInputSchema. The
        // model is constrained to emit one structured payload, no
        // markdown-fence-strip dance.
        let tool: [String: Any] = [
            "name": toolName,
            "description": toolDescription,
            "input_schema": toolInputSchema
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": toolName]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.anthropic.error("Claude request failed: \(error.localizedDescription, privacy: .public)")
            throw SynthesisProviderError.anthropicBadResponse(status: -1, body: error.localizedDescription)
        }
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw SynthesisProviderError.anthropicBadResponse(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw SynthesisProviderError.anthropicBadResponse(status: http.statusCode, body: bodyString)
        }

        // Pull the tool_use block matching the forced toolName. The
        // response can also carry a leading text block we ignore.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUseBlock = content.first(where: { ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName }),
              let input = toolUseBlock["input"] as? [String: Any] else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SynthesisProviderError.structuredOutputMalformed(preview: String(preview))
        }

        Logger.anthropic.info("Claude synthesis succeeded in \(duration, privacy: .public)s")
        return (input: input, duration: duration)
    }
}
