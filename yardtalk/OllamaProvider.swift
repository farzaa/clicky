//
//  OllamaProvider.swift
//  yardtalk
//
//  Local synthesis via Ollama (https://ollama.com), which exposes a REST
//  API on http://localhost:11434. We use the native `/api/chat` endpoint
//  with the `format` field set to the template's JSON Schema — Ollama
//  constrains the model's output to match the schema, so we get
//  schema-conformant JSON back without prompt-engineering tricks.
//
//  The user picks the model name in Settings (default: qwen2.5:14b).
//  They're responsible for `ollama pull`ing it; we surface a clear error
//  if the daemon isn't running or the model isn't installed.
//

import Foundation
import OSLog

extension Logger {
    static let ollama = Logger(subsystem: "com.yardtalk.app", category: "ollama")
}

final class OllamaProvider: SynthesisProvider {
    static let defaultBaseURLString = "http://localhost:11434"
    // Qwen3-14B Q4_K_M: ~9 GB resident on Apple Silicon, best-in-class
    // JSON schema adherence in its size class, leaves headroom for a
    // 24 GB Mac running Xcode + browser alongside. Power users on
    // 32+ GB machines should switch to `qwen3:30b-a3b-instruct-2507`
    // via Settings — same family, MoE, higher quality ceiling.
    static let defaultModel = "qwen3:14b"

    let kind: SynthesisProviderKind = .ollama
    let displayName: String

    private let baseURL: URL
    private let model: String
    private let session: URLSession

    init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
        self.displayName = "Ollama · \(model)"

        let config = URLSessionConfiguration.default
        // Local model first-token latency on a cold load can be 10-30s on
        // a 14B model; per-request budget is generous so we don't time out
        // before the model warms up.
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
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
        let chatURL = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `format` accepts either "json" or a full JSON Schema. Passing
        // the schema constrains output to it. `stream: false` so we get
        // the whole message in one response — the synthesis path is
        // non-streaming end-to-end.
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": toolInputSchema,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "options": [
                "num_predict": maxTokens,
                // temperature 0.2 keeps the model from drifting into
                // creative-writing territory on rehearsal/research notes.
                "temperature": 0.2
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.ollama.error("Ollama request failed: \(error.localizedDescription, privacy: .public)")
            throw SynthesisProviderError.ollamaUnreachable(detail: error.localizedDescription)
        }
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw SynthesisProviderError.ollamaUnreachable(detail: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw SynthesisProviderError.ollamaBadResponse(status: http.statusCode, body: bodyString)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SynthesisProviderError.ollamaBadResponse(status: http.statusCode, body: String(preview))
        }

        // `content` is a JSON-encoded string (because of `format: schema`)
        // — parse it into the dict shape buildNUPayload expects.
        guard let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            throw SynthesisProviderError.structuredOutputMalformed(preview: String(content.prefix(200)))
        }

        Logger.ollama.info("Ollama synthesis succeeded in \(duration, privacy: .public)s with model \(self.model, privacy: .public)")
        return (input: parsed, duration: duration)
    }
}
