//
//  AppleFoundationProvider.swift
//  yardtalk
//
//  On-device synthesis via Apple's FoundationModels framework (macOS 26+).
//  Zero install, zero key, runs on the Apple Neural Engine. Apple's
//  on-device model is ~3B params and tuned exactly for the kind of work
//  YardTalk does: summarization + extraction into a fixed structured shape.
//
//  Apple's structured-output story is compile-time, not runtime — the
//  framework wants an @Generable Swift type, not a JSON Schema dict. The
//  NU payload contract is frozen at four fields, so we hardcode one
//  @Generable struct here that matches both shipped templates
//  (PresentationPrep, ResearchNotes). If a future template diverges from
//  this shape, add another @Generable struct and switch on toolName.
//
//  The whole file is wrapped in `#if canImport(FoundationModels)` so the
//  app still compiles on older Xcode SDKs — on those, the provider just
//  isn't available at runtime and the resolver falls back to Ollama.
//

import Foundation
import OSLog

extension Logger {
    static let appleFoundation = Logger(subsystem: "com.yardtalk.app", category: "apple-foundation")
}

#if canImport(FoundationModels)
import FoundationModels

/// Four-field structured shape matching the frozen NU payload. Both
/// shipped templates (PresentationPrep, ResearchNotes) overlay their own
/// semantics on this skeleton — see their systemPrompt for the
/// per-template guidance the model actually follows. The @Guide text
/// here is intentionally generic so it doesn't pull the model away from
/// the template's framing.
@available(macOS 26.0, *)
@Generable
struct AppleSessionSynthesis {
    @Guide(description: "1-3 sentence overview. No preamble; start with the topic. Empty string only if the narration is unintelligible.")
    let summary: String

    @Guide(description: "Short declarative bullets the user can confidently state or build on. Empty array if the narration was too thin to surface any.")
    let accomplishments: [String]

    @Guide(description: "Open questions, unclear areas, or under-prepared sections. Empty array if none surfaced — do not invent.")
    let blockers: [String]

    @Guide(description: "Concrete next actions the user should take. Empty array if nothing actionable surfaced — do not invent.")
    let nextSteps: [String]
}

@available(macOS 26.0, *)
final class AppleFoundationProvider: SynthesisProvider {
    let kind: SynthesisProviderKind = .apple
    let displayName = "Apple on-device"

    static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    func synthesizeStructured(
        systemPrompt: String,
        userPrompt: String,
        toolName: String,
        toolDescription: String,
        toolInputSchema: [String: Any],
        maxTokens: Int
    ) async throws -> (input: [String: Any], duration: TimeInterval) {
        if case .unavailable(let reason) = Self.availability {
            throw SynthesisProviderError.appleUnavailable(reason: String(describing: reason))
        }

        Logger.appleFoundation.info("Synthesizing via Apple on-device model")
        let start = Date()
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(
            to: userPrompt,
            generating: AppleSessionSynthesis.self
        )
        let duration = Date().timeIntervalSince(start)
        let result = response.content

        // Re-shape the typed Swift result into the [String: Any] dict
        // that buildNUPayload consumes. Keys must match the JSON Schema
        // field names exactly (snake_case for next_steps).
        let input: [String: Any] = [
            "summary": result.summary,
            "accomplishments": result.accomplishments,
            "blockers": result.blockers,
            "next_steps": result.nextSteps
        ]
        return (input: input, duration: duration)
    }
}

#endif
