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
        latestTranscript: String
    ) -> SkillWriteTrigger? {
        guard !sessionTrace.isEmpty else { return nil }

        let normalizedTranscript = latestTranscript.lowercased()
        let pointedExchanges = sessionTrace.filter(\.pointed)
        let topic = deriveTopic(from: sessionTrace)

        if confirmationPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return SkillWriteTrigger(reason: .userConfirmed, topic: topic)
        }

        if pointedExchanges.count >= 2 {
            return SkillWriteTrigger(reason: .multiStepPointing, topic: topic)
        }

        if hasRepeatedTopic(in: sessionTrace) {
            return SkillWriteTrigger(reason: .repeatedTopic, topic: topic)
        }

        return nil
    }

    static func deriveTopic(from sessionTrace: [SessionTraceEntry]) -> String {
        let combined = sessionTrace
            .map(\.userTranscript)
            .joined(separator: " ")
        let tokens = SkillMatcher.tokenize(combined)
        return tokens.prefix(6).joined(separator: " ")
    }

    private static func hasRepeatedTopic(in sessionTrace: [SessionTraceEntry]) -> Bool {
        guard sessionTrace.count >= 2 else { return false }
        let tokenSets = sessionTrace.map { Set(SkillMatcher.tokenize($0.userTranscript)) }
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

    static func isScreenTeachingSession(_ sessionTrace: [SessionTraceEntry]) -> Bool {
        sessionTrace.contains(where: \.pointed) ||
        sessionTrace.contains(where: { $0.bundleId != nil })
    }
}
