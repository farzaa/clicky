//
//  OutputTemplate.swift
//  yardtalk
//
//  The pluggable abstraction that lets a session produce different kinds
//  of output. M2 ships only `.nuPayload` implementers (text synthesis);
//  M8 will add `.videoBundle` implementers backed by HyperFrames. Both
//  consume the same `SessionContext` so a session's transcripts, clips,
//  and markers feed every output channel uniformly.
//
//  The protocol is intentionally narrow — concrete subprotocols
//  (`NUPayloadTemplate`, future `VideoBundleTemplate`) carry the
//  domain-specific render API. `OutputTemplate` itself just gives the
//  picker UI something to enumerate.
//

import Foundation

enum OutputKind {
    case nuPayload
    case videoBundle  // reserved for M8 (HyperFrames-driven video output)
}

enum OutputArtifact {
    case nuPayload(NUSessionPayload)
    case videoBundle(URL)
}

protocol OutputTemplate {
    var id: String { get }
    var displayName: String { get }
    var kind: OutputKind { get }
}

/// Templates that produce a structured NU payload from a session's
/// narration. Implementers own the prompt and the LLM tool schema; the
/// `SynthesisService` does the Claude call and feeds the tool input
/// back into `payload(from:context:)` for final assembly.
///
/// Splitting prompt/schema (template) from the network call (service)
/// keeps templates pure and testable — they can be exercised against a
/// recorded tool_use response without touching the network.
protocol NUPayloadTemplate: OutputTemplate {
    func systemPrompt(for context: SessionContext) -> String
    func userPrompt(for context: SessionContext) -> String
    /// Returns the JSON-encoded `input_schema` for the tool that Claude
    /// must emit. Returning `[String: Any]` rather than a Codable struct
    /// because the Anthropic Messages API accepts arbitrary JSON Schema
    /// and pinning to a Swift type would make it harder to evolve the
    /// schema per template.
    func toolInputSchema(for context: SessionContext) -> [String: Any]
    /// The tool's name. Used in `tool_choice` to force structured output.
    var toolName: String { get }
    /// Convert Claude's tool_use input into the final payload, stamping
    /// the project/session metadata that the LLM didn't (and shouldn't)
    /// generate — names, ids, timestamps.
    func payload(from toolInput: [String: Any], context: SessionContext) throws -> NUSessionPayload
}

extension NUPayloadTemplate {
    /// Default assembly: take the four AI-generated fields out of
    /// `toolInput`, stamp the project/session metadata, return the
    /// payload. Templates that want different semantics can override
    /// `payload(from:context:)` directly.
    ///
    /// Parsing is permissive — Claude occasionally returns `null` for
    /// required array fields when nothing surfaces (e.g., `blockers`
    /// is null on a session with no problems). The prompts explicitly
    /// say "empty array if none surfaced", so missing/null/wrong-type
    /// are treated the same way. Strict decoding here loses entire
    /// payloads to a single null and makes the user re-run synthesis
    /// for no reason.
    func buildNUPayload(
        from toolInput: [String: Any],
        context: SessionContext
    ) throws -> NUSessionPayload {
        let summary = stringOrEmpty(toolInput["summary"])
        let accomplishments = stringArrayOrEmpty(toolInput["accomplishments"])
        let blockers = stringArrayOrEmpty(toolInput["blockers"])
        let nextSteps = stringArrayOrEmpty(toolInput["next_steps"])

        let endedAt = context.session.endedAt ?? Date()
        let references = NUSessionPayload.References(
            reportURL: nil,
            clipIDs: context.session.clipIDs.map { $0.uuidString }
        )

        return NUSessionPayload(
            source: NUSessionPayload.source,
            project: context.project.name,
            projectType: context.project.type.rawValue,
            sessionStart: context.session.startedAt,
            sessionEnd: endedAt,
            summary: summary,
            accomplishments: accomplishments,
            blockers: blockers,
            nextSteps: nextSteps,
            references: references,
            testMode: NUSessionPayload.defaultTestMode,
            schemaVersion: NUSessionPayload.schemaVersion
        )
    }

    private func stringOrEmpty(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    /// Coerces `Any?` to `[String]`, tolerating null/missing and
    /// mixed-type arrays. Non-string elements are dropped rather
    /// than crashing the whole payload — Claude sometimes mixes a
    /// trailing object or number into an otherwise-string array.
    private func stringArrayOrEmpty(_ value: Any?) -> [String] {
        if let direct = value as? [String] { return direct }
        if let mixed = value as? [Any] {
            return mixed.compactMap { $0 as? String }
        }
        return []
    }
}

/// The everything-template-needs view of a session. Computed fresh from
/// the live stores at synthesis time; templates never mutate it.
struct SessionContext {
    let project: YardTalkProject
    let session: YardTalkSession
    /// Clips ordered by `recordedAt` ascending (chronological). Empty
    /// transcripts and missing transcripts are both included — the
    /// template decides how to present them.
    let clips: [YardTalkClip]

    /// Concatenated narration as a single string, with each clip's
    /// transcript prefixed by its session-relative timestamp. Convenient
    /// for prompts that just want the story; templates wanting more
    /// structure can read `clips` directly.
    var narrationTranscript: String {
        var lines: [String] = []
        for clip in clips {
            let offset = clip.recordedAt.timeIntervalSince(session.startedAt)
            let stamp = formatOffset(offset)
            let body = (clip.transcript?.isEmpty == false ? clip.transcript! : "(no speech detected)")
            lines.append("[\(stamp)] \(body)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Markers across all clips, expressed as session-relative timestamps
    /// with the owning clip's id. Templates that drive cuts (M8) want
    /// these; text templates may surface them as "noteworthy moments."
    var allMarkers: [(clipID: UUID, sessionOffset: TimeInterval)] {
        clips.flatMap { clip in
            clip.markers.map { marker in
                let clipStart = clip.recordedAt.timeIntervalSince(session.startedAt)
                return (clip.id, clipStart + marker)
            }
        }
    }

    private func formatOffset(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
