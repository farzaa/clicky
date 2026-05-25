//
//  SkillMatcher.swift
//  leanring-buddy
//
//  Matches teaching skills to the current app and user transcript.
//

import Foundation

struct SkillMatch: Equatable {
    let skill: TeachingSkill
    let score: Int
}

enum SkillMatcher {
    static let topicStopwords: Set<String> = [
        "how", "do", "does", "did", "can", "could", "would", "should", "what", "where", "when", "why", "which",
        "the", "this", "that", "these", "those", "a", "an", "my", "your", "me", "you", "and", "or", "but",
        "is", "are", "was", "were", "be", "been", "being", "to", "in", "on", "at", "for", "of", "with", "from",
        "please", "help", "show", "tell", "explain", "use", "using", "got", "thanks", "thank", "worked", "perfect"
    ]

    static func meaningfulTokens(_ text: String) -> [String] {
        tokenize(text).filter { !topicStopwords.contains($0) }
    }

    static func matchSkills(
        from skills: [TeachingSkill],
        bundleId: String?,
        transcript: String,
        limit: Int = 3
    ) -> [SkillMatch] {
        let queryTokens = tokenize(transcript)
        let eligibleSkills = skills.filter { skill in
            skill.status != .archived || skill.isPinned
        }

        let scored = eligibleSkills.compactMap { skill -> SkillMatch? in
            var score = 0

            if let bundleId, skill.bundleIds.contains(bundleId) {
                score += 12
            }

            let haystackTokens = Set(
                tokenize(skill.name) +
                tokenize(skill.description) +
                tokenize(skill.body)
            )
            score += queryTokens.filter { haystackTokens.contains($0) }.count

            if skill.status == .active {
                score += 1
            }
            score += min(skill.usageCount, 5)

            return score > 0 ? SkillMatch(skill: skill, score: score) : nil
        }

        return Array(
            scored
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return (lhs.skill.lastUsed ?? .distantPast) > (rhs.skill.lastUsed ?? .distantPast)
                }
                .prefix(limit)
        )
    }

    static func findSimilarSkill(
        in skills: [TeachingSkill],
        bundleId: String?,
        topic: String
    ) -> TeachingSkill? {
        let topicTokens = Set(tokenize(topic))
        guard !topicTokens.isEmpty else { return nil }

        let candidates = skills.filter { skill in
            guard let bundleId else { return true }
            return skill.bundleIds.isEmpty || skill.bundleIds.contains(bundleId)
        }

        return candidates.max { lhs, rhs in
            overlapScore(lhs, topicTokens: topicTokens) < overlapScore(rhs, topicTokens: topicTokens)
        }
        .flatMap { candidate in
            overlapScore(candidate, topicTokens: topicTokens) >= 2 ? candidate : nil
        }
    }

    private static func overlapScore(_ skill: TeachingSkill, topicTokens: Set<String>) -> Int {
        let skillTokens = Set(
            tokenize(skill.name) +
            tokenize(skill.description) +
            tokenize(skill.body)
        )
        return topicTokens.filter { skillTokens.contains($0) }.count
    }

    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}
