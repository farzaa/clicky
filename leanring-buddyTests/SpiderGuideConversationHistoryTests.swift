//
//  SpiderGuideConversationHistoryTests.swift
//  leanring-buddyTests
//
//  Tests for local guide conversation history retention.
//

import Foundation
import Testing
@testable import Spider

struct SpiderGuideConversationHistoryTests {
    @Test func keepsOnlyMostRecentGuideTurnsInOrder() {
        var history = SpiderGuideConversationHistory()
        let totalTurns = SpiderContentLimits.maxVisionConversationHistoryTurns + 3

        for index in 1...totalTurns {
            history.append(
                userTranscript: "user \(index)",
                assistantResponse: "spider \(index)"
            )
        }

        #expect(history.count == SpiderContentLimits.maxVisionConversationHistoryTurns)
        #expect(history.turns.first?.userTranscript == "user 4")
        #expect(history.turns.first?.assistantResponse == "spider 4")
        #expect(history.turns.last?.userTranscript == "user \(totalTurns)")
        #expect(history.turns.last?.assistantResponse == "spider \(totalTurns)")
    }

    @Test func removeAllClearsLocalGuideTurns() {
        var history = SpiderGuideConversationHistory()
        history.append(userTranscript: "private transcript", assistantResponse: "private response")

        history.removeAll()

        #expect(history.count == 0)
        #expect(history.turns.isEmpty)
    }
}
