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
    - user preferences and constraints from the session (e.g. keyboard only, no menu)
    - completion signals ("user said got it", visible ui state)

    keep it concise, practical, and specific to macos ui teaching. all lowercase.
    """

    private static let patchSystemPrompt = """
    you update an existing teaching skill for clicky, a screen-native voice tutor that points at ui elements.

    given the existing skill body and a new tutoring session, produce an updated markdown body only. do not include yaml frontmatter.

    patch-first rules:
    - preserve guidance that still works
    - merge new constraints and refinements from the latest session
    - do not duplicate steps or create a parallel workflow
    - honor user preferences such as "keyboard only" or "avoid the menu"
    - keep ordered steps, ui labels, shortcuts, pointing heuristics, and completion signals

    keep it concise, practical, and specific to macos ui teaching. all lowercase.
    """

    static func synthesizeSkillContent(
        sessionTrace: [SessionTraceEntry],
        trigger: SkillWriteTrigger,
        existingSkill: TeachingSkill?,
        targetBundleId: String?,
        claudeAPI: ClaudeAPI
    ) async throws -> (name: String, description: String, body: String) {
        let sessionSummary = renderSessionSummary(
            sessionTrace,
            trigger: trigger,
            existingSkill: existingSkill,
            targetBundleId: targetBundleId
        )
        let primaryQuestion = SkillTriggerEvaluator.primaryTeachingQuestion(from: sessionTrace) ?? trigger.topic
        let metadata = TeachingSkill.buildMetadata(primaryQuestion: primaryQuestion, bundleId: targetBundleId)

        let userPrompt: String
        let systemPrompt: String
        if let existingSkill {
            systemPrompt = patchSystemPrompt
            userPrompt = """
            patch this existing teaching skill using the new session. preserve useful existing guidance and merge refinements:

            existing skill id: \(existingSkill.id)
            existing skill body:
            \(existingSkill.body)

            new session:
            \(sessionSummary)
            """
        } else {
            systemPrompt = synthesisSystemPrompt
            userPrompt = "create a new teaching skill from this session:\n\n\(sessionSummary)"
        }

        let response = try await claudeAPI.sendTextMessage(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 1200
        )

        let cleanedBody = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = existingSkill?.name ?? metadata.name
        let description = existingSkill?.description ?? metadata.description
        return (name: name, description: description, body: cleanedBody)
    }

    static func buildSkillMetadata(
        sessionTrace: [SessionTraceEntry],
        trigger: SkillWriteTrigger,
        targetBundleId: String?
    ) -> TeachingSkill.Metadata {
        let primaryQuestion = SkillTriggerEvaluator.primaryTeachingQuestion(from: sessionTrace) ?? trigger.topic
        return TeachingSkill.buildMetadata(primaryQuestion: primaryQuestion, bundleId: targetBundleId)
    }

    static func buildSkill(
        id: String?,
        name: String,
        description: String,
        body: String,
        targetBundleId: String?,
        taskSlug: String?,
        primaryQuestion: String,
        existingSkill: TeachingSkill?
    ) -> TeachingSkill {
        let resolvedID = id
            ?? existingSkill?.id
            ?? TeachingSkill.stableSkillId(bundleId: targetBundleId, primaryQuestion: primaryQuestion)
        let resolvedTaskSlug = taskSlug ?? existingSkill?.taskSlug ?? TeachingSkill.taskSlug(from: primaryQuestion)

        let bundleIds: [String]
        if let targetBundleId {
            bundleIds = [targetBundleId]
        } else if let existingSkill, !existingSkill.bundleIds.isEmpty {
            bundleIds = existingSkill.bundleIds
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
            taskSlug: resolvedTaskSlug,
            body: body
        )
    }

    private static func renderSessionSummary(
        _ sessionTrace: [SessionTraceEntry],
        trigger: SkillWriteTrigger,
        existingSkill: TeachingSkill?,
        targetBundleId: String?
    ) -> String {
        var lines: [String] = []
        lines.append("trigger: \(trigger.reason.rawValue)")
        lines.append("topic: \(trigger.topic)")
        lines.append("target bundle id: \(targetBundleId ?? "unknown")")
        if let primaryQuestion = SkillTriggerEvaluator.primaryTeachingQuestion(from: sessionTrace) {
            lines.append("primary question: \(primaryQuestion)")
        }
        if let existingSkill {
            lines.append("existing skill id: \(existingSkill.id)")
        }

        for (index, entry) in sessionTrace.enumerated() {
            lines.append("exchange \(index + 1):")
            lines.append("user: \(entry.userTranscript)")
            lines.append("assistant: \(entry.assistantResponse)")
            lines.append("frontmost bundle id: \(entry.bundleId ?? "unknown")")
            lines.append("pointed: \(entry.pointed ? "yes" : "no")")
        }

        return lines.joined(separator: "\n")
    }
}
