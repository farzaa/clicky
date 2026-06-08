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
        case screenTeaching
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

    static func isScreenTeachingSession(_ sessionTrace: [SessionTraceEntry]) -> Bool {
        sessionTrace.contains(where: \.pointed) ||
        sessionTrace.contains(where: { $0.bundleId != nil }) ||
        sessionTrace.contains { entry in
            TeachingSkill.detectBundleId(in: entry.userTranscript) != nil ||
            TeachingSkill.detectBundleId(in: entry.assistantResponse) != nil
        }
    }
}
