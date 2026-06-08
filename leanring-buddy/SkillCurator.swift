//
//  SkillCurator.swift
//  leanring-buddy
//
//  Maintains the teaching skill library over time.
//

import Foundation

enum SkillCurator {
    private static let staleAfterDays = 30
    private static let archiveAfterDays = 90
    private static let maxMergePassesPerLaunch = 1
    private static let maxPatchPassesPerLaunch = 1

    private static var mergePassesUsedThisLaunch = 0
    private static var patchPassesUsedThisLaunch = 0

    static func curate(store: TeachingSkillStore, now: Date = Date()) {
        curateTimeBasedLifecycle(store: store, now: now)
    }

    static func curateTimeBasedLifecycle(store: TeachingSkillStore, now: Date = Date()) {
        let calendar = Calendar.current

        for skill in store.skills {
            guard !skill.isPinned else { continue }
            guard let lastUsed = skill.lastUsed else { continue }

            let daysSinceUse = calendar.dateComponents([.day], from: lastUsed, to: now).day ?? 0
            var updated = skill
            var skillChanged = false

            if daysSinceUse >= archiveAfterDays, updated.status != .archived {
                updated.status = .archived
                skillChanged = true
            } else if daysSinceUse >= staleAfterDays, updated.status == .active {
                updated.status = .stale
                skillChanged = true
            }

            if skillChanged {
                try? store.saveSkill(updated)
            }
        }
    }

    static func curateWithLLMPasses(store: TeachingSkillStore, claudeAPI: ClaudeAPI) async {
        await mergeOneDuplicatePairIfNeeded(store: store, claudeAPI: claudeAPI)
        await patchOneStaleSkillIfNeeded(store: store, claudeAPI: claudeAPI)
    }

    private static func mergeOneDuplicatePairIfNeeded(
        store: TeachingSkillStore,
        claudeAPI: ClaudeAPI
    ) async {
        guard mergePassesUsedThisLaunch < maxMergePassesPerLaunch else { return }

        let duplicatePairs = SkillMatcher.findDuplicateSkillPairs(in: store.skills)
        guard let duplicatePair = duplicatePairs.first else { return }

        do {
            let mergedSkill = try await mergeDuplicateSkills(
                primarySkill: duplicatePair.primarySkill,
                duplicateSkill: duplicatePair.duplicateSkill,
                claudeAPI: claudeAPI
            )
            _ = try store.saveSkill(mergedSkill)
            try store.deleteSkill(id: duplicatePair.duplicateSkill.id)
            mergePassesUsedThisLaunch += 1
            ClickyAnalytics.trackTeachingSkillMerged(
                primarySkillID: duplicatePair.primarySkill.id,
                duplicateSkillID: duplicatePair.duplicateSkill.id
            )
            print("📚 Curator merged duplicate skills: \(duplicatePair.duplicateSkill.id) → \(duplicatePair.primarySkill.id)")
        } catch {
            print("⚠️ Curator failed to merge duplicate skills: \(error)")
        }
    }

    private static func patchOneStaleSkillIfNeeded(
        store: TeachingSkillStore,
        claudeAPI: ClaudeAPI
    ) async {
        guard patchPassesUsedThisLaunch < maxPatchPassesPerLaunch else { return }

        guard let staleSkill = store.skills.first(where: { $0.status == .stale && !$0.isPinned }) else {
            return
        }

        do {
            let patchedSkill = try await patchStaleSkill(staleSkill, claudeAPI: claudeAPI)
            _ = try store.saveSkill(patchedSkill)
            patchPassesUsedThisLaunch += 1
            ClickyAnalytics.trackTeachingSkillPatched(skillID: staleSkill.id)
            print("📚 Curator patched stale skill: \(staleSkill.id)")
        } catch {
            print("⚠️ Curator failed to patch stale skill \(staleSkill.id): \(error)")
        }
    }

    private static let mergeSystemPrompt = """
    you merge duplicate teaching skills for clicky, a screen-native voice tutor.

    given two similar skills, produce a single merged markdown body only. do not include yaml frontmatter.

    preserve the best steps, ui labels, pointing tips, and completion signals from both skills.
    remove redundancy. keep it concise and practical. all lowercase.
    """

    private static let patchSystemPrompt = """
    you refresh stale teaching skills for clicky when macos app ui may have changed.

    given an existing teaching skill, produce an updated markdown body only. do not include yaml frontmatter.

    keep the same workflow intent but update ui labels, menu paths, and pointing heuristics for current macos ui.
    note any labels that may have changed. all lowercase.
    """

    private static func mergeDuplicateSkills(
        primarySkill: TeachingSkill,
        duplicateSkill: TeachingSkill,
        claudeAPI: ClaudeAPI
    ) async throws -> TeachingSkill {
        let userPrompt = """
        merge these duplicate teaching skills into one improved skill body.

        primary skill (\(primarySkill.name)):
        \(primarySkill.body)

        duplicate skill (\(duplicateSkill.name)):
        \(duplicateSkill.body)
        """

        let response = try await claudeAPI.sendTextMessage(
            systemPrompt: mergeSystemPrompt,
            userPrompt: userPrompt,
            maxTokens: 1200
        )

        var mergedSkill = primarySkill
        mergedSkill.body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        mergedSkill.usageCount = primarySkill.usageCount + duplicateSkill.usageCount
        mergedSkill.lastUsed = Date()
        mergedSkill.status = .active
        return mergedSkill
    }

    private static func patchStaleSkill(
        _ staleSkill: TeachingSkill,
        claudeAPI: ClaudeAPI
    ) async throws -> TeachingSkill {
        let userPrompt = """
        refresh this stale teaching skill for current macos ui:

        skill name: \(staleSkill.name)
        description: \(staleSkill.description)
        bundle ids: \(staleSkill.bundleIds.joined(separator: ", "))

        existing body:
        \(staleSkill.body)
        """

        let response = try await claudeAPI.sendTextMessage(
            systemPrompt: patchSystemPrompt,
            userPrompt: userPrompt,
            maxTokens: 1200
        )

        var patchedSkill = staleSkill
        patchedSkill.body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        patchedSkill.status = .active
        patchedSkill.lastUsed = Date()
        return patchedSkill
    }
}
