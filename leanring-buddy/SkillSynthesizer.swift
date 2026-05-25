//
//  SkillSynthesizer.swift
//  leanring-buddy
//
//  Drafts or updates teaching skills from a completed tutoring session trace.
//

import Foundation

enum SkillSynthesizer {
    private static let synthesisSystemPrompt = """
    you write teaching skills for clicky, a screen-native voice tutor that points at ui elements.

    given a tutoring session transcript, produce a markdown teaching skill body only. do not include yaml frontmatter.

    include:
    - the app/workflow being taught
    - ordered steps
    - exact ui labels, menu paths, and shortcuts when known
    - pointing heuristics (what to point at first, what to avoid)
    - common mistakes the user made or might make
    - completion signals ("user said got it", visible ui state)

    keep it concise, practical, and specific to macos ui teaching. all lowercase.
    """

    static func synthesizeSkillContent(
        sessionTrace: [SessionTraceEntry],
        trigger: SkillWriteTrigger,
        existingSkill: TeachingSkill?,
        claudeAPI: ClaudeAPI
    ) async throws -> (name: String, description: String, body: String) {
        let sessionSummary = renderSessionSummary(sessionTrace, trigger: trigger, existingSkill: existingSkill)
        let userPrompt = existingSkill == nil
            ? "create a new teaching skill from this session:\n\n\(sessionSummary)"
            : "update this teaching skill using the new session. preserve useful existing guidance and improve it:\n\nexisting skill:\n\(existingSkill?.body ?? "")\n\nnew session:\n\(sessionSummary)"

        let response = try await claudeAPI.sendTextMessage(
            systemPrompt: synthesisSystemPrompt,
            userPrompt: userPrompt,
            maxTokens: 1200
        )

        let cleanedBody = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "teach-\(trigger.topic.replacingOccurrences(of: " ", with: "-"))"
        let name = existingSkill?.name ?? fallbackName
        let description = existingSkill?.description ?? "Teach the user how to \(trigger.topic)"
        return (name: name, description: description, body: cleanedBody)
    }

    static func buildSkill(
        id: String?,
        name: String,
        description: String,
        body: String,
        bundleId: String?,
        existingSkill: TeachingSkill?
    ) -> TeachingSkill {
        let resolvedID = id ?? existingSkill?.id ?? TeachingSkill.slug(from: name)
        let bundleIds: [String]
        if let existingSkill, !existingSkill.bundleIds.isEmpty {
            bundleIds = existingSkill.bundleIds
        } else if let bundleId {
            bundleIds = [bundleId]
        } else {
            bundleIds = []
        }

        return TeachingSkill(
            id: resolvedID,
            name: name,
            description: description,
            bundleIds: bundleIds,
            status: .active,
            lastUsed: Date(),
            usageCount: existingSkill?.usageCount ?? 0,
            isPinned: existingSkill?.isPinned ?? false,
            body: body
        )
    }

    private static func renderSessionSummary(
        _ sessionTrace: [SessionTraceEntry],
        trigger: SkillWriteTrigger,
        existingSkill: TeachingSkill?
    ) -> String {
        var lines: [String] = []
        lines.append("trigger: \(trigger.reason.rawValue)")
        lines.append("topic: \(trigger.topic)")
        if let existingSkill {
            lines.append("existing skill id: \(existingSkill.id)")
        }

        for (index, entry) in sessionTrace.enumerated() {
            lines.append("exchange \(index + 1):")
            lines.append("user: \(entry.userTranscript)")
            lines.append("assistant: \(entry.assistantResponse)")
            lines.append("bundle id: \(entry.bundleId ?? "unknown")")
            lines.append("pointed: \(entry.pointed ? "yes" : "no")")
        }

        return lines.joined(separator: "\n")
    }
}
