//
//  Memory.swift
//  leanring-buddy
//
//  Category-aware memory model for the unified memories UI. Skills map in
//  today; preference and routine adapters will plug in when generators land.
//

import Foundation

struct Memory: Identifiable, Equatable, Codable {
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

    init(
        id: String,
        category: MemoryCategory,
        title: String,
        summary: String,
        body: String,
        bundleIds: [String] = [],
        status: TeachingSkillStatus = .active,
        isPinned: Bool = false,
        usageCount: Int = 0,
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.body = body
        self.bundleIds = bundleIds
        self.status = status
        self.isPinned = isPinned
        self.usageCount = usageCount
        self.lastUsed = lastUsed
    }

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

    func relativeSavedLabel(now: Date = Date()) -> String {
        Memory.relativeSavedLabel(lastUsed: lastUsed, now: now)
    }

    static func relativeSavedLabel(lastUsed: Date?, now: Date = Date()) -> String {
        guard let lastUsed else { return "Saved just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Saved \(formatter.localizedString(for: lastUsed, relativeTo: now))"
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

    var pluralDisplayLabel: String {
        switch self {
        case .skill: return "Skills"
        case .preference: return "Preferences"
        case .routine: return "Routines"
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .skill:
            return "No skills yet. Teach Clicky something on screen and confirm it worked."
        case .preference:
            return "No preferences yet. Clicky will save these as it learns how you like to work."
        case .routine:
            return "No routines yet. Clicky will save these when it notices repeated workflows."
        }
    }

    var systemImageName: String {
        switch self {
        case .skill: return "lightbulb"
        case .preference: return "slider.horizontal.3"
        case .routine: return "arrow.triangle.2.circlepath"
        }
    }
}
