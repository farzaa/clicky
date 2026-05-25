//
//  TeachingSkillTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

struct TeachingSkillTests {
    @Test func parsesSkillFrontmatterAndBody() throws {
        let markdown = """
        ---
        name: teach-xcode-source-control
        description: Walk through committing in Xcode
        bundleIds:
          - com.apple.dt.Xcode
        status: active
        lastUsed: 2026-05-24
        usageCount: 3
        pinned: true
        ---

        step one: open source control.
        step two: click commit.
        """

        let skill = try #require(TeachingSkill.parse(id: "teach-xcode-source-control", markdown: markdown))
        #expect(skill.name == "teach-xcode-source-control")
        #expect(skill.description == "Walk through committing in Xcode")
        #expect(skill.bundleIds == ["com.apple.dt.Xcode"])
        #expect(skill.usageCount == 3)
        #expect(skill.isPinned)
        #expect(skill.body.contains("step one"))
    }

    @Test func matchesSkillsByBundleAndKeywords() {
        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "teach-textedit-save",
            description: "Save a document in TextEdit",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 2,
            isPinned: false,
            body: "click file then save or use command s"
        )

        let matches = SkillMatcher.matchSkills(
            from: [skill],
            bundleId: "com.apple.TextEdit",
            transcript: "how do I save this document?"
        )

        #expect(matches.count == 1)
        #expect(matches.first?.skill.id == "teach-textedit-save")
    }

    @Test func triggerFiresOnUserConfirmation() {
        let trace = [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do I save this?",
                assistantResponse: "click file then save",
                bundleId: "com.apple.TextEdit",
                pointed: true
            )
        ]

        let trigger = SkillTriggerEvaluator.shouldWriteSkill(
            sessionTrace: trace,
            latestTranscript: "got it thanks that worked"
        )

        #expect(trigger?.reason == .userConfirmed)
    }

    @Test func promptBuilderInjectsMatchedSkills() {
        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Save a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: nil,
            usageCount: 0,
            isPinned: false,
            body: "use file > save"
        )

        let prompt = TeachingPromptBuilder.buildVoiceResponsePrompt(
            basePrompt: "base prompt",
            matchedSkills: [skill]
        )

        #expect(prompt.contains("base prompt"))
        #expect(prompt.contains("teaching skills:"))
        #expect(prompt.contains("Save in TextEdit"))
        #expect(prompt.contains("use file > save"))
    }
}
