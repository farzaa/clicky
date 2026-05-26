//
//  ResearchNotesTemplate.swift
//  yardtalk
//
//  M2 second template. Frames a session as "thinking aloud while
//  reading, comparing sources, or working through findings" and
//  produces structured research notes: theme overview (summary), key
//  insights (accomplishments), open questions or unclear areas
//  (blockers), and follow-up reads or experiments (next_steps).
//

import Foundation

struct ResearchNotesTemplate: NUPayloadTemplate {
    let id = "research_notes"
    let displayName = "Research Notes"
    let kind: OutputKind = .nuPayload
    let toolName = "emit_research_notes_summary"

    func systemPrompt(for context: SessionContext) -> String {
        """
        You are organizing a research session into themed notes. The user \
        narrated their thinking while reading, comparing sources, or \
        working through ideas. The narration is the entire signal — there \
        are no documents attached. Your job is to produce:

        1. A 1-3 sentence overview of the session's theme (summary).
        2. Key findings or insights the user surfaced (accomplishments). \
           When the user named a source, paper, or concept, include it \
           verbatim — those are search anchors for them later.
        3. Open questions or areas that stayed unclear (blockers).
        4. Recommended next reads, follow-up experiments, or questions to \
           ask domain experts (next_steps).

        Rules:
        - Group findings by sub-theme when one emerges. Prefix the bullet \
          with the sub-theme in title case, e.g., \"Privacy: …\".
        - Quote the user verbatim when a phrasing is sharp or specific.
        - If the narration is too thin to populate a list, return an empty \
          array. Do not invent content — the user trusts this output.
        - Do not address the user in second person. Write notes for them \
          to read later, in third person or imperative.
        """
    }

    func userPrompt(for context: SessionContext) -> String {
        let durationMinutes = Int(
            (context.session.endedAt ?? Date())
                .timeIntervalSince(context.session.startedAt) / 60
        )
        let markersBlock: String
        if context.allMarkers.isEmpty {
            markersBlock = "(no markers)"
        } else {
            let lines = context.allMarkers.map { entry -> String in
                let t = formatOffset(entry.sessionOffset)
                return "- \(t) (clip \(entry.clipID.uuidString.prefix(8)))"
            }
            markersBlock = lines.joined(separator: "\n")
        }

        return """
        Project: \(context.project.name) (\(context.project.type.displayName))
        Session duration: \(durationMinutes) min
        Clips recorded: \(context.clips.count)

        NARRATION (timestamps are session-relative; \"(no speech detected)\" \
        means the clip had no narration):

        \(context.narrationTranscript)

        MARKERS the user dropped during recording (these moments are the \
        ones they flagged as important; weight them in your prioritization):

        \(markersBlock)

        Emit the structured research notes via the \(toolName) tool now.
        """
    }

    func toolInputSchema(for context: SessionContext) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "1-3 sentence overview of the session's theme."
                ],
                "accomplishments": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Key findings or insights, ideally prefixed by sub-theme. Empty array if narration was too thin."
                ],
                "blockers": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Open questions or unclear areas. Empty array if none surfaced."
                ],
                "next_steps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Recommended next reads or follow-up actions. Empty array if nothing actionable surfaced."
                ]
            ],
            "required": ["summary", "accomplishments", "blockers", "next_steps"]
        ]
    }

    func payload(from toolInput: [String: Any], context: SessionContext) throws -> NUSessionPayload {
        try buildNUPayload(from: toolInput, context: context)
    }

    private func formatOffset(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Maps a project type to its default template. The picker UI in M3
/// will let the user override this per session, but auto-trigger on
/// session end uses this as the default.
enum DefaultTemplate {
    static func forProjectType(_ type: YardTalkProjectType) -> any NUPayloadTemplate {
        switch type {
        case .presentationPrep: return PresentationPrepTemplate()
        case .researchNotes: return ResearchNotesTemplate()
        }
    }
}
