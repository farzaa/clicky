//
//  SpiderGuideConversationHistory.swift
//  leanring-buddy
//
//  Bounded in-memory conversation turns for guide requests. This type does
//  not log, persist, sanitize, or emit analytics for transcript/model text.
//

import Foundation

struct SpiderGuideConversationHistory {
    private(set) var turns: [(userTranscript: String, assistantResponse: String)] = []

    var count: Int {
        turns.count
    }

    mutating func append(userTranscript: String, assistantResponse: String) {
        turns.append((userTranscript: userTranscript, assistantResponse: assistantResponse))
        trimToMaximumTurnCount()
    }

    mutating func removeAll() {
        turns.removeAll()
    }

    private mutating func trimToMaximumTurnCount() {
        let overflowCount = turns.count - SpiderContentLimits.maxVisionConversationHistoryTurns
        guard overflowCount > 0 else { return }
        turns.removeFirst(overflowCount)
    }
}
