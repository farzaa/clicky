//
//  Memory.swift
//  leanring-buddy
//
//  Category-aware memory model for the unified memories UI. Skills map in
//  today; preference and routine adapters will plug in when generators land.
//

import Foundation

struct Memory: Identifiable, Equatable {
    let id: String
    let category: MemoryCategory
    var title: String
    var summary: String
    var body: String
    var bundleIds: [String]
    var status: TeachingSkillStatus
    var isPinned: Bool
    var usageCount: Int
    var lastUsed: Date?

    init(skill: TeachingSkill) {
        id = skill.id
        category = .skill
        title = skill.name
        summary = skill.description
        body = skill.body
        bundleIds = skill.bundleIds
        status = skill.status
        isPinned = skill.isPinned
        usageCount = skill.usageCount
        lastUsed = skill.lastUsed
    }

    static func filtered(
        _ memories: [Memory],
        category: MemoryCategory?,
        status: TeachingSkillStatus?
    ) -> [Memory] {
        memories.filter { memory in
            let categoryMatches = category.map { memory.category == $0 } ?? true
            let statusMatches = status.map { memory.status == $0 } ?? true
            return categoryMatches && statusMatches
        }
    }
}

struct MemoryEdit: Equatable {
    var title: String
    var summary: String
    var body: String
    var bundleIds: [String]
    var status: TeachingSkillStatus

    init(from memory: Memory) {
        title = memory.title
        summary = memory.summary
        body = memory.body
        bundleIds = memory.bundleIds
        status = memory.status
    }
}

extension MemoryCategory {
    var displayLabel: String {
        switch self {
        case .skill: return "Skill"
        case .preference: return "Preference"
        case .routine: return "Routine"
        }
    }
}
