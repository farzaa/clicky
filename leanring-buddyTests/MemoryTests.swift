//
//  MemoryTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite(.serialized)
struct MemoryTests {
    @Test func memoryAdapterMapsTeachingSkillFields() {
        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 2,
            isPinned: true,
            taskSlug: "save",
            body: "click file then save"
        )

        let memory = Memory(skill: skill)

        #expect(memory.id == skill.id)
        #expect(memory.category == .skill)
        #expect(memory.title == skill.name)
        #expect(memory.summary == skill.description)
        #expect(memory.body == skill.body)
        #expect(memory.bundleIds == skill.bundleIds)
        #expect(memory.status == skill.status)
        #expect(memory.isPinned == skill.isPinned)
        #expect(memory.usageCount == skill.usageCount)
        #expect(memory.lastUsed == skill.lastUsed)
    }

    @Test func memoryEditCopiesEditableFieldsFromMemory() {
        let memory = Memory(skill: TeachingSkill(
            id: "teach-xcode-commit",
            name: "Commit in Xcode",
            description: "Source control walkthrough",
            bundleIds: ["com.apple.dt.Xcode"],
            status: .stale,
            lastUsed: nil,
            usageCount: 1,
            isPinned: false,
            taskSlug: "commit",
            body: "open source control"
        ))

        let edit = MemoryEdit(from: memory)

        #expect(edit.title == memory.title)
        #expect(edit.summary == memory.summary)
        #expect(edit.body == memory.body)
        #expect(edit.bundleIds == memory.bundleIds)
        #expect(edit.status == memory.status)
    }

    @Test func filteredMemoriesRespectsCategoryAndStatus() {
        let activeSkill = Memory(skill: TeachingSkill(
            id: "teach-a",
            name: "A",
            description: "A",
            bundleIds: [],
            status: .active,
            lastUsed: nil,
            usageCount: 1,
            isPinned: false,
            taskSlug: nil,
            body: "a"
        ))
        let archivedSkill = Memory(skill: TeachingSkill(
            id: "teach-b",
            name: "B",
            description: "B",
            bundleIds: [],
            status: .archived,
            lastUsed: nil,
            usageCount: 2,
            isPinned: false,
            taskSlug: nil,
            body: "b"
        ))

        let allMemories = [activeSkill, archivedSkill]

        #expect(Memory.filtered(allMemories, category: .skill, status: .active) == [activeSkill])
        #expect(Memory.filtered(allMemories, category: .skill, status: .archived) == [archivedSkill])
        #expect(Memory.filtered(allMemories, category: .preference, status: nil).isEmpty)
        #expect(Memory.filtered(allMemories, category: nil, status: nil).count == 2)
    }

    @Test func updateMemoryRoundTripsThroughSkillStore() throws {
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-memory-tests-\(UUID().uuidString)", isDirectory: true)

        try ClickyTestHomeIsolation.withIsolatedHome(isolatedHome) {
            let store = TeachingSkillStore()
            let originalSkill = TeachingSkill(
                id: "teach-textedit-save",
                name: "Save in TextEdit",
                description: "Original description",
                bundleIds: ["com.apple.TextEdit"],
                status: .active,
                lastUsed: nil,
                usageCount: 0,
                isPinned: false,
                taskSlug: "save",
                body: "original body"
            )
            try store.saveSkill(originalSkill)

            var updatedSkill = try #require(store.skill(withID: originalSkill.id))
            updatedSkill.name = "Updated title"
            updatedSkill.description = "Updated summary"
            updatedSkill.body = "updated body"
            updatedSkill.bundleIds = ["com.apple.dt.Xcode"]
            updatedSkill.status = .archived
            try store.saveSkill(updatedSkill)

            store.loadSkills()
            let loadedSkill = try #require(store.skill(withID: originalSkill.id))
            let loadedMemory = Memory(skill: loadedSkill)

            #expect(loadedMemory.title == "Updated title")
            #expect(loadedMemory.summary == "Updated summary")
            #expect(loadedMemory.body == "updated body")
            #expect(loadedMemory.bundleIds == ["com.apple.dt.Xcode"])
            #expect(loadedMemory.status == .archived)
            #expect(loadedMemory.id == originalSkill.id)
        }
    }

    @Test func deleteMemoryRemovesSkillFromStore() throws {
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-memory-tests-\(UUID().uuidString)", isDirectory: true)

        try ClickyTestHomeIsolation.withIsolatedHome(isolatedHome) {
            let store = TeachingSkillStore()
            let skill = TeachingSkill(
                id: "teach-textedit-save",
                name: "Save in TextEdit",
                description: "Walkthrough",
                bundleIds: ["com.apple.TextEdit"],
                status: .active,
                lastUsed: nil,
                usageCount: 0,
                isPinned: false,
                taskSlug: "save",
                body: "body"
            )
            try store.saveSkill(skill)
            #expect(store.skills.count == 1)

            try store.deleteSkill(id: skill.id)
            store.loadSkills()

            #expect(store.skills.isEmpty)
        }
    }

    @Test func relativeSavedLabelUsesFriendlyText() {
        let now = Date()
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        #expect(Memory.relativeSavedLabel(lastUsed: nil, now: now) == "Saved just now")
        #expect(Memory.relativeSavedLabel(lastUsed: twoDaysAgo, now: now).hasPrefix("Saved "))
    }
}
