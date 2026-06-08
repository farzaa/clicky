//
//  ClickyPathsTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

// Serialized because these tests mutate the shared `ClickyPaths.overrideHomeForTesting`
// global. Without this, Swift Testing's default parallel execution lets them clobber
// each other's override and produces flaky failures.
@Suite(.serialized)
struct ClickyPathsTests {
    @Test func defaultHomeUsesClickyDirectoryInUserHome() {
        ClickyPaths.overrideHomeForTesting = nil

        let expectedHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky", isDirectory: true)

        #expect(ClickyPaths.home == expectedHome)
    }

    @Test func overrideHomeRedirectsSkillsAndTopicHistory() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            ClickyPaths.overrideHomeForTesting = nil
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        ClickyPaths.overrideHomeForTesting = temporaryHome

        #expect(ClickyPaths.home == temporaryHome)
        #expect(ClickyPaths.skills == temporaryHome.appendingPathComponent("skills", isDirectory: true))
        #expect(ClickyPaths.topicHistory == temporaryHome.appendingPathComponent("topic-history.json"))
    }

    @Test func teachingSkillStoreUsesClickyPathsSkillsDirectory() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            ClickyPaths.overrideHomeForTesting = nil
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        ClickyPaths.overrideHomeForTesting = temporaryHome

        #expect(TeachingSkillStore.skillsRootURL == ClickyPaths.skills)
    }

    @Test func teachingTopicHistoryStoreUsesClickyPathsTopicHistoryFile() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            ClickyPaths.overrideHomeForTesting = nil
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        ClickyPaths.overrideHomeForTesting = temporaryHome

        #expect(TeachingTopicHistoryStore.historyFileURL == ClickyPaths.topicHistory)
    }

    @Test func teachingSkillStoreWritesToIsolatedHome() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            ClickyPaths.overrideHomeForTesting = nil
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        ClickyPaths.overrideHomeForTesting = temporaryHome

        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "teach-textedit-save",
            description: "Save in TextEdit",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: nil,
            usageCount: 0,
            isPinned: false,
            taskSlug: nil,
            body: "step one: press command-s."
        )

        let store = TeachingSkillStore()
        _ = try store.saveSkill(skill)

        let skillFile = temporaryHome
            .appendingPathComponent("skills/teach-textedit-save/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillFile.path))
    }
}
