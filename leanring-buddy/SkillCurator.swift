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

    static func curate(store: TeachingSkillStore, now: Date = Date()) {
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
}
