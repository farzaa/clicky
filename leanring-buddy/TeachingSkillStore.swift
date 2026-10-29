//
//  TeachingSkillStore.swift
//  leanring-buddy
//
//  Local filesystem storage for teaching skills under ~/.clicky/skills/.
//

import Foundation

final class TeachingSkillStore {
    static var skillsRootURL: URL {
        ClickyPaths.skills
    }

    private(set) var skills: [TeachingSkill] = []

    func loadSkills() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.skillsRootURL, withIntermediateDirectories: true)

        guard let folders = try? fileManager.contentsOfDirectory(
            at: Self.skillsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            skills = []
            return
        }

        var loaded: [TeachingSkill] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard let markdown = try? String(contentsOf: skillFile, encoding: .utf8),
                  let skill = TeachingSkill.parse(id: folder.lastPathComponent, markdown: markdown) else {
                continue
            }
            loaded.append(skill)
        }

        skills = loaded.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    func saveSkill(_ skill: TeachingSkill) throws -> TeachingSkill {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: skill.folderURL, withIntermediateDirectories: true)
        try skill.serialize().write(to: skill.fileURL, atomically: true, encoding: .utf8)
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
        skills.sort { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return skill
    }

    func deleteSkill(id: String) throws {
        let folder = Self.skillsRootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.removeItem(at: folder)
        skills.removeAll { $0.id == id }
    }

    func skill(withID id: String) -> TeachingSkill? {
        skills.first { $0.id == id }
    }

    func markUsed(_ skill: TeachingSkill) throws -> TeachingSkill {
        var updated = skill
        updated.lastUsed = Date()
        updated.usageCount += 1
        if updated.status == .stale {
            updated.status = .active
        }
        return try saveSkill(updated)
    }

    func setPinned(id: String, pinned: Bool) throws {
        guard var skill = skill(withID: id) else { return }
        skill.isPinned = pinned
        _ = try saveSkill(skill)
    }

    func restoreSkill(id: String) throws {
        guard var skill = skill(withID: id) else { return }
        skill.status = .active
        skill.lastUsed = Date()
        _ = try saveSkill(skill)
    }

    func skills(withStatus status: TeachingSkillStatus?) -> [TeachingSkill] {
        guard let status else { return skills }
        return skills.filter { $0.status == status }
    }
}
