//
//  MemoryGateTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite(.serialized)
struct MemoryGateTests {
    private func makeSession(
        sessionId: UUID = UUID(),
        outcome: SessionOutcome = .success,
        privacyOptOut: Bool = false,
        turns: [SessionTraceEntry]
    ) -> PersistedSession {
        let startedAt = turns.first?.timestamp ?? Date()
        let endedAt = turns.last?.timestamp ?? startedAt
        let appsUsed = turns.compactMap(\.bundleId).reduce(into: [String]()) { result, bundleId in
            if !result.contains(bundleId) {
                result.append(bundleId)
            }
        }

        return PersistedSession(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            outcome: outcome,
            privacyOptOut: privacyOptOut,
            appsUsed: appsUsed,
            turns: turns
        )
    }

    @Test func passesSkillOnUserConfirmation() {
        let session = makeSession(turns: [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do i save this?",
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
        ])

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        #expect(decision.shouldDistillSkill)
        #expect(decision.passes(.skill))
        #expect(decision.passedCategories[.skill]?.contains(.userConfirmed) == true)
        #expect(decision.blockReasons.isEmpty)
    }

    @Test func passesSkillOnMultiStepPointingWithoutConfirmation() {
        let session = makeSession(
            outcome: .unknown,
            turns: [
                SessionTraceEntry(
                    timestamp: Date(),
                    userTranscript: "how do i save this document?",
                    assistantResponse: "click file then save",
                    bundleId: "com.apple.TextEdit",
                    pointed: true
                ),
                SessionTraceEntry(
                    timestamp: Date(),
                    userTranscript: "where is the save button?",
                    assistantResponse: "pointing at file menu",
                    bundleId: "com.apple.TextEdit",
                    pointed: true
                )
            ]
        )

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        #expect(decision.shouldDistillSkill)
        #expect(decision.passedCategories[.skill]?.contains(.multiStepPointing) == true)
        #expect(decision.passedCategories[.skill]?.contains(.userConfirmed) == false)
    }

    @Test func blocksWhenPrivacyOptOut() {
        let session = makeSession(
            privacyOptOut: true,
            turns: [
                SessionTraceEntry(
                    timestamp: Date(),
                    userTranscript: "got it thanks",
                    assistantResponse: "great",
                    bundleId: "com.apple.TextEdit",
                    pointed: true
                )
            ]
        )

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        #expect(!decision.shouldDistillSkill)
        #expect(decision.blockReasons == [.privacyOptOut])
    }

    @Test func blocksWhenLearningDisabled() {
        let session = makeSession(turns: [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "got it thanks",
                assistantResponse: "great",
                bundleId: "com.apple.TextEdit",
                pointed: true
            )
        ])

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: false
        )

        #expect(!decision.shouldDistillSkill)
        #expect(decision.blockReasons == [.learningDisabled])
    }

    @Test func blocksAbandonedSessionWithoutConfirmation() {
        let session = makeSession(
            outcome: .abandoned,
            turns: [
                SessionTraceEntry(
                    timestamp: Date(),
                    userTranscript: "how do i save this?",
                    assistantResponse: "click file then save",
                    bundleId: "com.apple.TextEdit",
                    pointed: true
                )
            ]
        )

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        #expect(!decision.shouldDistillSkill)
        #expect(decision.blockReasons == [.abandonedWithoutConfirmation])
    }

    @Test func blocksGenericOffScreenQA() {
        let session = makeSession(turns: [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "what is the capital of france?",
                assistantResponse: "paris",
                bundleId: nil,
                pointed: false
            )
        ])

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        #expect(!decision.shouldDistillSkill)
        #expect(decision.blockReasons == [.genericOffScreenQA])
    }

    @Test func passesSkillOnRepeatedTopic() throws {
        let tempHistoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-memory-gate-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempHistoryURL) }

        let topicHistoryStore = TeachingTopicHistoryStore(historyFileURL: tempHistoryURL)
        topicHistoryStore.load()

        let bundleId = "com.apple.TextEdit"
        let topic = "save document"

        topicHistoryStore.recordTopic(topic: topic, bundleId: bundleId)
        topicHistoryStore.recordTopic(topic: topic, bundleId: bundleId)

        let session = makeSession(
            outcome: .unknown,
            turns: [
                SessionTraceEntry(
                    timestamp: Date(),
                    userTranscript: "how do i save this document?",
                    assistantResponse: "click file then save",
                    bundleId: bundleId,
                    pointed: true
                )
            ]
        )

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: topicHistoryStore.entries,
            isLearningEnabled: true
        )

        #expect(decision.shouldDistillSkill)
        #expect(decision.passedCategories[.skill]?.contains(.repeatedTopic) == true)
    }

    @Test func aggregatesMultipleGateReasons() throws {
        let session = makeSession(turns: [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do i save this document?",
                assistantResponse: "click file then save",
                bundleId: "com.apple.TextEdit",
                pointed: true
            ),
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "where is the save button?",
                assistantResponse: "pointing at file menu",
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
        ])

        let decision = MemoryGate.evaluate(
            session: session,
            topicHistory: [],
            isLearningEnabled: true
        )

        let reasons = try #require(decision.passedCategories[.skill])
        #expect(reasons.contains(.userConfirmed))
        #expect(reasons.contains(.multiStepPointing))
        #expect(reasons.contains(.screenTeaching))
    }

    @Test func makeSkillWriteTriggerUsesPrimaryGateReason() {
        let session = makeSession(turns: [
            SessionTraceEntry(
                timestamp: Date(),
                userTranscript: "how do i save this document?",
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
        ])

        let trigger = MemoryGate.makeSkillWriteTrigger(
            for: session,
            gateReasons: [.userConfirmed, .screenTeaching]
        )

        #expect(trigger.reason == .userConfirmed)
        #expect(trigger.topic == "save document")
    }
}
