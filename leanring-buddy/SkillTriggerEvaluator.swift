//
//  SkillTriggerEvaluator.swift
//  leanring-buddy
//
//  Decides when a tutoring session should create or update a teaching skill.
//

import Foundation

struct SkillWriteTrigger: Equatable {
    enum Reason: String, Equatable {
        case userConfirmed
        case multiStepPointing
        case repeatedTopic
    }

    let reason: Reason
    let topic: String
}

enum SkillTriggerEvaluator {
    private static let confirmationPhrases = [
        "got it",
        "that worked",
        "thanks that worked",
        "thank you that worked",
        "perfect",
        "helpful",
        "makes sense now",
        "that helps"
    ]

    static func shouldWriteSkill(
        sessionTrace: [SessionTraceEntry],
        latestTranscript: String,
        topicHistory: [TeachingTopicHistoryEntry] = []
    ) -> SkillWriteTrigger? {
        guard !sessionTrace.isEmpty else { return nil }

        let normalizedTranscript = latestTranscript.lowercased()
        let pointedExchanges = sessionTrace.filter(\.pointed)
        let topic = deriveTopic(from: sessionTrace)
        let bundleId = sessionTrace.compactMap(\.bundleId).last

        if confirmationPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return SkillWriteTrigger(reason: .userConfirmed, topic: topic)
        }

        if pointedExchanges.count >= 2 {
            return SkillWriteTrigger(reason: .multiStepPointing, topic: topic)
        }

        if hasRepeatedTopic(in: sessionTrace) {
            return SkillWriteTrigger(reason: .repeatedTopic, topic: topic)
        }

        if hasCrossSessionRepeatedTopic(
            topic: topic,
            bundleId: bundleId,
            topicHistory: topicHistory
        ) {
            return SkillWriteTrigger(reason: .repeatedTopic, topic: topic)
        }

        return nil
    }

    static func primaryTeachingQuestion(from sessionTrace: [SessionTraceEntry]) -> String? {
        sessionTrace
            .map(\.userTranscript)
            .first { !isConfirmationTranscript($0) }
    }

    static func isConfirmationTranscript(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return confirmationPhrases.contains { normalized.contains($0) }
    }

    static func deriveTopic(from sessionTrace: [SessionTraceEntry]) -> String {
        guard let primaryQuestion = primaryTeachingQuestion(from: sessionTrace) else { return "" }
        return deriveTopic(fromQuestion: primaryQuestion)
    }

    static func deriveTopic(fromQuestion question: String) -> String {
        let tokens = SkillMatcher.meaningfulTokens(question)
        return tokens.prefix(6).joined(separator: " ")
    }

    private static func hasRepeatedTopic(in sessionTrace: [SessionTraceEntry]) -> Bool {
        let teachingEntries = sessionTrace.filter { !isConfirmationTranscript($0.userTranscript) }
        guard teachingEntries.count >= 2 else { return false }

        let tokenSets = teachingEntries.map { Set(SkillMatcher.meaningfulTokens($0.userTranscript)) }
        for index in tokenSets.indices {
            for otherIndex in tokenSets.indices where otherIndex > index {
                let overlap = tokenSets[index].intersection(tokenSets[otherIndex])
                if overlap.count >= 2 {
                    return true
                }
            }
        }
        return false
    }

    private static func hasCrossSessionRepeatedTopic(
        topic: String,
        bundleId: String?,
        topicHistory: [TeachingTopicHistoryEntry]
    ) -> Bool {
        let topicTokens = Set(SkillMatcher.meaningfulTokens(topic))
        guard topicTokens.count >= 1 else { return false }

        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let matchingEntries = topicHistory.filter { entry in
            entry.timestamp >= cutoff &&
            bundleIdsMatch(entry.bundleId, bundleId) &&
            entry.topicTokens.filter { topicTokens.contains($0) }.count >= 2
        }

        return matchingEntries.count >= 2
    }

    private static func bundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            return left == right
        case (nil, _), (_, nil):
            return true
        }
    }

    static func isScreenTeachingSession(_ sessionTrace: [SessionTraceEntry]) -> Bool {
        sessionTrace.contains(where: \.pointed) ||
        sessionTrace.contains(where: { $0.bundleId != nil })
    }
}
