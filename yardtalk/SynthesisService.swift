//
//  SynthesisService.swift
//  yardtalk
//
//  Drives end-of-session synthesis: takes a `SessionContext` + an
//  `NUPayloadTemplate`, asks the configured `SynthesisProvider` (Apple
//  on-device or Ollama) to emit a structured payload, and returns the
//  assembled `NUSessionPayload`. Templates own the prompts and schema;
//  this service owns the call into the provider.
//
//  The provider is optional — `init(provider:)` accepts nil so the rest
//  of the app boots even when no provider has been resolved yet. The
//  resolver in CompanionManager normally picks Apple if available and
//  Ollama otherwise, so this is mostly a defensive guard.
//

import Foundation
import OSLog
import Observation

extension Logger {
    static let synthesis = Logger(subsystem: "com.yardtalk.app", category: "synthesis")
}

@MainActor
@Observable
final class SynthesisService {
    enum Status: Equatable {
        case idle
        case running(sessionID: UUID)
        case failed(sessionID: UUID, message: String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored
    var provider: SynthesisProvider?

    init(provider: SynthesisProvider?) {
        self.provider = provider
    }

    /// Runs the template against the context, returning the assembled
    /// payload. Throws `SynthesisError.notConfigured` if no provider
    /// has been resolved.
    func synthesize(
        context: SessionContext,
        template: NUPayloadTemplate
    ) async throws -> NUSessionPayload {
        guard let provider else {
            throw SynthesisError.notConfigured
        }

        Logger.synthesis.info("Synthesizing session \(context.session.id.uuidString, privacy: .public) with template \(template.id, privacy: .public) via \(provider.displayName, privacy: .public)")
        status = .running(sessionID: context.session.id)

        do {
            let (toolInput, duration) = try await provider.synthesizeStructured(
                systemPrompt: template.systemPrompt(for: context),
                userPrompt: template.userPrompt(for: context),
                toolName: template.toolName,
                toolDescription: "Emit the structured session summary for the YardTalk \(template.displayName) template.",
                toolInputSchema: template.toolInputSchema(for: context),
                maxTokens: 4096
            )

            let payload = try template.payload(from: toolInput, context: context)
            // Persistent product-quality log — captures the raw tool
            // input + anomaly summary so we can grep history when
            // tuning prompts. Independent of synthesisError on the
            // session, which only reflects the most recent attempt.
            SynthesisLog.shared.appendSuccess(
                context: context,
                template: template,
                toolInput: toolInput,
                claudeDurationSeconds: duration
            )
            Logger.synthesis.info("Synthesis succeeded in \(duration, privacy: .public)s")
            status = .idle
            return payload
        } catch {
            SynthesisLog.shared.appendError(
                context: context,
                template: template,
                error: error
            )
            Logger.synthesis.error("Synthesis failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(sessionID: context.session.id, message: error.localizedDescription)
            throw error
        }
    }
}

enum SynthesisError: LocalizedError {
    case notConfigured
    case toolInputDecodeFailed(field: String)
    case noClips

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No synthesis provider configured. Open Settings (gear icon in the panel header) to pick Apple on-device or Ollama."
        case .toolInputDecodeFailed(let field):
            return "Synthesis output was missing or malformed for field \"\(field)\"."
        case .noClips:
            return "Cannot synthesize an empty session — record at least one clip first."
        }
    }
}
