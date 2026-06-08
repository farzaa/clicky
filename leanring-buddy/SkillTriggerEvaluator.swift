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

    /// Negations that flip an otherwise positive phrase ("not helpful",
    /// "didn't work"). Stored apostrophe-free because `words(from:)` strips
    /// apostrophes before tokenizing.
    private static let negationTokens: Set<String> = [
        "not", "never", "dont", "doesnt", "didnt",
        "isnt", "wasnt", "wont", "wouldnt", "couldnt", "cant"
    ]

    static func isConfirmationTranscript(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }

        let transcriptWords = words(from: normalized)
        let transcriptWordSet = Set(transcriptWords)

        // A negation anywhere in the transcript means the user did not confirm
        // success ("not helpful", "that didn't work").
        guard negationTokens.isDisjoint(with: transcriptWordSet) else { return false }

        // Match each phrase on whole-word boundaries so "imperfect" does not
        // match "perfect" and "unhelpful" does not match "helpful".
        return confirmationPhrases.contains { phrase in
            containsContiguousWords(words(from: phrase), in: transcriptWords)
        }
    }

    private static func words(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func containsContiguousWords(_ phraseWords: [String], in transcriptWords: [String]) -> Bool {
        guard !phraseWords.isEmpty, phraseWords.count <= transcriptWords.count else { return false }
        for startIndex in 0...(transcriptWords.count - phraseWords.count) {
            if Array(transcriptWords[startIndex..<startIndex + phraseWords.count]) == phraseWords {
                return true
            }
        }
        return false
    }

    static func deriveTopic(from sessionTrace: [SessionTraceEntry]) -> String {
        guard let primaryQuestion = primaryTeachingQuestion(from: sessionTrace) else { return "" }
        return deriveTopic(fromQuestion: primaryQuestion)
    }

    static func deriveTopic(fromQuestion question: String) -> String {
        let tokens = SkillMatcher.meaningfulTokens(question)
        return tokens.prefix(6).joined(separator: " ")
    }

    /// A session counts as screen teaching only when the cursor pointed at the UI
    /// or the user/assistant explicitly named an app. The mere presence of a
    /// frontmost `bundleId` is NOT enough: `recordSessionExchange` stamps the
    /// frontmost app on every turn, so a generic off-screen question asked while
    /// any app happens to be focused would otherwise look like screen teaching.
    static func isScreenTeachingSession(_ sessionTrace: [SessionTraceEntry]) -> Bool {
        sessionTrace.contains(where: \.pointed) ||
        sessionTrace.contains { entry in
            TeachingSkill.detectBundleId(in: entry.userTranscript) != nil ||
            TeachingSkill.detectBundleId(in: entry.assistantResponse) != nil
        }
    }
}
