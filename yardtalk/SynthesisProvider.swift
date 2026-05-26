//
//  SynthesisProvider.swift
//  yardtalk
//
//  Abstraction over the model that turns a session's narration into a
//  structured NU payload. Templates own the prompts + JSON Schema; the
//  provider owns the call into the model and the JSON-back-to-dict
//  round trip.
//
//  The signature is lifted from the original Anthropic tool-use path so
//  SynthesisService and the templates stay unchanged when providers
//  swap. Providers that don't support arbitrary JSON Schema at runtime
//  (the Apple on-device model needs a compile-time @Generable type) map
//  their typed result back into a [String: Any] dict shaped like the
//  schema before returning.
//

import Foundation

protocol SynthesisProvider {
    var kind: SynthesisProviderKind { get }
    var displayName: String { get }

    /// Run the structured-synthesis call. The returned dict must conform
    /// to `toolInputSchema` so `NUPayloadTemplate.buildNUPayload` can
    /// consume it unchanged.
    func synthesizeStructured(
        systemPrompt: String,
        userPrompt: String,
        toolName: String,
        toolDescription: String,
        toolInputSchema: [String: Any],
        maxTokens: Int
    ) async throws -> (input: [String: Any], duration: TimeInterval)
}

enum SynthesisProviderKind: String, CaseIterable, Codable {
    case apple
    case ollama
    case anthropic

    /// Short label used in the segmented picker. Keep these one word
    /// so three of them fit comfortably across a ~320pt panel.
    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .ollama: return "Ollama"
        case .anthropic: return "Claude"
        }
    }
}

enum SynthesisProviderError: LocalizedError {
    case appleUnavailable(reason: String)
    case ollamaUnreachable(detail: String)
    case ollamaBadResponse(status: Int, body: String)
    case anthropicBadResponse(status: Int, body: String)
    case structuredOutputMalformed(preview: String)

    var errorDescription: String? {
        switch self {
        case .appleUnavailable(let reason):
            return "Apple on-device model unavailable: \(reason). Switch provider in Settings or enable Apple Intelligence."
        case .ollamaUnreachable(let detail):
            return "Couldn't reach Ollama: \(detail). Make sure `ollama serve` is running and you've pulled a model (e.g. `ollama pull qwen3:14b`)."
        case .ollamaBadResponse(let status, let body):
            return "Ollama returned HTTP \(status): \(body.prefix(200))"
        case .anthropicBadResponse(let status, let body):
            return "Claude API returned HTTP \(status): \(body.prefix(200))"
        case .structuredOutputMalformed(let preview):
            return "Model output wasn't valid JSON for the requested schema. Preview: \(preview)"
        }
    }
}
