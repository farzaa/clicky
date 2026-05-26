//
//  PresentationPrepTemplate.swift
//  yardtalk
//
//  M2 first template. Frames a session as "thinking out loud while
//  preparing a presentation" and produces structured rehearsal notes:
//  outline (summary), confident talking points (accomplishments), weak
//  spots that need rehearsal (blockers), and to-dos before delivery
//  (next_steps). The four-field shape matches the frozen NU contract
//  exactly — different templates reuse the slots with different
//  semantics, and the assistant runtime on the NU side reads them as
//  generic structured notes.
//

import Foundation

struct PresentationPrepTemplate: NUPayloadTemplate {
    let id = "presentation_prep"
    let displayName = "Presentation Prep"
    let kind: OutputKind = .nuPayload
    let toolName = "emit_presentation_prep_summary"

    func systemPrompt(for context: SessionContext) -> String {
        """
        You are a tough, helpful editor turning a recorded presentation-prep \
        session into structured rehearsal notes. The user narrated their \
        thinking aloud while building slides, refining a story, or working \
        through ideas. Their narration is the entire signal — there are no \
        slides attached. Your job is to distill what was said into:

        1. A concise outline of the presentation as it currently stands (summary).
        2. Specific talking points the user can confidently make (accomplishments).
        3. Sections that sounded uncertain, hand-wavy, or under-prepared, and \
           which would not yet survive a hostile audience (blockers).
        4. Concrete things to do before delivering the talk (next_steps).

        Rules:
        - Use short, declarative bullets — no preamble, no hedging.
        - When the user said something memorable, quote them briefly.
        - If the narration is too thin to populate a list, return an empty \
          array for it. Do not invent content. The user will see this output \
          and trust it.
        - Do not address the user in second person ("you should…"). Write \
          rehearsal notes for them to read, in third person or imperative.
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

        NARRATION (timestamps are session-relative; "(no speech detected)" \
        means the clip had no narration — usually a silent demo):

        \(context.narrationTranscript)

        MARKERS the user dropped during recording (these moments are \
        important to them and should weight your prioritization):

        \(markersBlock)

        Emit the structured rehearsal notes via the \(toolName) tool now.
        """
    }

    func toolInputSchema(for context: SessionContext) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "1-3 sentence outline of the presentation as it currently stands. No preamble; start with the topic."
                ],
                "accomplishments": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Talking points the user can confidently make. Short declarative bullets. Empty array if narration was too thin."
                ],
                "blockers": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Sections that sounded uncertain or under-prepared. Empty array if none surfaced."
                ],
                "next_steps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Concrete things to do before delivering. Empty array if nothing actionable surfaced."
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
