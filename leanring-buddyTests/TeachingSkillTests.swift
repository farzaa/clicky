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
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
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

    @Test func topicIgnoresConfirmationPhrase() {
        let trace = [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do I save this document?",
                assistantResponse: "click file then save",
                bundleId: "com.apple.TextEdit",
                pointed: true
            ),
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "got it thanks that worked",
                assistantResponse: "great",
                bundleId: "com.apple.TextEdit",
                pointed: false
            )
        ]

        let topic = SkillTriggerEvaluator.deriveTopic(from: trace)
        #expect(topic == "save document")
        #expect(SkillTriggerEvaluator.primaryTeachingQuestion(from: trace) == "how do I save this document?")
    }

    @Test func slugAndNameAreCleanForSaveQuestionWithConfirmation() throws {
        let trace = [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do I save this document?",
                assistantResponse: "click file then save",
                bundleId: "com.apple.TextEdit",
                pointed: true
            ),
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "got it thanks that worked",
                assistantResponse: "great",
                bundleId: "com.apple.TextEdit",
                pointed: false
            )
        ]

        let trigger = SkillTriggerEvaluator.shouldWriteSkill(
            sessionTrace: trace,
            latestTranscript: "got it thanks that worked"
        )
        let metadata = SkillSynthesizer.buildSkillMetadata(
            sessionTrace: trace,
            trigger: try #require(trigger),
            bundleId: "com.apple.TextEdit"
        )

        #expect(metadata.id == "teach-textedit-save")
        #expect(metadata.name == "Save in TextEdit")
        #expect(metadata.description == "Walk the user through save document")
        #expect(!metadata.id.contains("got"))
        #expect(!metadata.id.contains("thanks"))
        #expect(!metadata.id.contains("worked"))
    }

    @Test func crossSessionRepeatDetectionWithin7Days() throws {
        let tempHistoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-topic-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempHistoryURL) }

        let topicHistoryStore = TeachingTopicHistoryStore(historyFileURL: tempHistoryURL)
        topicHistoryStore.load()

        let bundleId = "com.apple.TextEdit"
        let topic = "save document"

        topicHistoryStore.recordTopic(topic: topic, bundleId: bundleId)

        let trace = [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do I save this document?",
                assistantResponse: "click file then save",
                bundleId: bundleId,
                pointed: true
            )
        ]

        topicHistoryStore.recordTopic(topic: topic, bundleId: bundleId)

        let trigger = SkillTriggerEvaluator.shouldWriteSkill(
            sessionTrace: trace,
            latestTranscript: "how do I save this document?",
            topicHistory: topicHistoryStore.entries
        )

        #expect(trigger?.reason == .repeatedTopic)
        #expect(trigger?.topic == "save document")
    }

    @Test func promptBuilderInjectsMatchedSkills() {
        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
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

    @Test func matchedSkillAppearsInComposedPrompt() {
        let skill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: nil,
            usageCount: 0,
            isPinned: false,
            body: "click file then save or use command s"
        )

        let matches = SkillMatcher.matchSkills(
            from: [skill],
            bundleId: "com.apple.TextEdit",
            transcript: "how do I save this document?"
        )
        let matchedSkills = matches.map(\.skill)
        let prompt = TeachingPromptBuilder.buildVoiceResponsePrompt(
            basePrompt: "companion voice prompt",
            matchedSkills: matchedSkills
        )

        #expect(matchedSkills.map(\.name) == ["Save in TextEdit"])
        #expect(prompt.contains("Save in TextEdit"))
        #expect(prompt.contains("click file then save or use command s"))
    }

    @Test func detectsDuplicateSkillsWithOverlappingContent() {
        let saveSkill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 3,
            isPinned: false,
            body: "click file then save or use command s shortcut"
        )
        let duplicateSaveSkill = TeachingSkill(
            id: "teach-textedit-save-document",
            name: "Save document in TextEdit",
            description: "Help save the current document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date().addingTimeInterval(-86400),
            usageCount: 1,
            isPinned: false,
            body: "open file menu then choose save for the document"
        )

        let duplicatePairs = SkillMatcher.findDuplicateSkillPairs(
            in: [saveSkill, duplicateSaveSkill],
            minimumOverlapScore: 3
        )

        #expect(duplicatePairs.count == 1)
        #expect(duplicatePairs.first?.primarySkill.id == "teach-textedit-save")
        #expect(duplicatePairs.first?.duplicateSkill.id == "teach-textedit-save-document")
    }

    @Test func ignoresPinnedSkillsForDuplicateDetection() {
        let pinnedSkill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 3,
            isPinned: true,
            body: "click file then save or use command s shortcut"
        )
        let overlappingSkill = TeachingSkill(
            id: "teach-textedit-save-copy",
            name: "Save document in TextEdit",
            description: "Help save the current document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 1,
            isPinned: false,
            body: "click file then save or use command s shortcut"
        )

        let duplicatePairs = SkillMatcher.findDuplicateSkillPairs(
            in: [pinnedSkill, overlappingSkill],
            minimumOverlapScore: 3
        )

        #expect(duplicatePairs.isEmpty)
    }

    @Test func ignoresSkillsWithDifferentBundleIdsForDuplicateDetection() {
        let textEditSkill = TeachingSkill(
            id: "teach-textedit-save",
            name: "Save in TextEdit",
            description: "Walk the user through saving a document",
            bundleIds: ["com.apple.TextEdit"],
            status: .active,
            lastUsed: Date(),
            usageCount: 3,
            isPinned: false,
            body: "click file then save or use command s shortcut"
        )
        let xcodeSkill = TeachingSkill(
            id: "teach-xcode-save",
            name: "Save in Xcode",
            description: "Walk the user through saving a file",
            bundleIds: ["com.apple.dt.Xcode"],
            status: .active,
            lastUsed: Date(),
            usageCount: 1,
            isPinned: false,
            body: "click file then save or use command s shortcut"
        )

        let duplicatePairs = SkillMatcher.findDuplicateSkillPairs(
            in: [textEditSkill, xcodeSkill],
            minimumOverlapScore: 3
        )

        #expect(duplicatePairs.isEmpty)
    }
}
