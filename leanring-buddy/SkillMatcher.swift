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

struct DuplicateSkillPair: Equatable {
    let primarySkill: TeachingSkill
    let duplicateSkill: TeachingSkill
    let overlapScore: Int
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
        findSkillForUpdate(
            in: skills,
            targetBundleId: bundleId,
            primaryQuestion: topic
        )
    }

    static func findSkillForUpdate(
        in skills: [TeachingSkill],
        targetBundleId: String?,
        primaryQuestion: String
    ) -> TeachingSkill? {
        let resolvedTargetBundleId = TeachingSkill.detectBundleId(in: primaryQuestion) ?? targetBundleId
        let expectedSkillId = TeachingSkill.stableSkillId(
            bundleId: resolvedTargetBundleId,
            primaryQuestion: primaryQuestion
        )
        let expectedTaskSlug = TeachingSkill.taskSlug(from: primaryQuestion)

        if let exactMatch = skills.first(where: { $0.id == expectedSkillId }) {
            return exactMatch
        }

        if let resolvedTargetBundleId {
            let bundleMatches = skills.filter { skill in
                skill.bundleIds.contains(resolvedTargetBundleId) &&
                (skill.taskSlug == expectedTaskSlug || skill.id.hasSuffix("-\(expectedTaskSlug)"))
            }

            if let bestBundleMatch = bundleMatches.max(by: { lhs, rhs in
                if lhs.usageCount != rhs.usageCount { return lhs.usageCount < rhs.usageCount }
                return (lhs.lastUsed ?? .distantPast) < (rhs.lastUsed ?? .distantPast)
            }) {
                return bestBundleMatch
            }
        }

        let topicTokens = Set(meaningfulTokens(primaryQuestion))
        guard !topicTokens.isEmpty else { return nil }

        let candidates = skills.filter { skill in
            guard let resolvedTargetBundleId else { return true }
            return skill.bundleIds.isEmpty || skill.bundleIds.contains(resolvedTargetBundleId)
        }

        return candidates.max { lhs, rhs in
            overlapScore(lhs, topicTokens: topicTokens) < overlapScore(rhs, topicTokens: topicTokens)
        }
        .flatMap { candidate in
            overlapScore(candidate, topicTokens: topicTokens) >= 2 ? candidate : nil
        }
    }

    static func tokenOverlapScore(between leftSkill: TeachingSkill, and rightSkill: TeachingSkill) -> Int {
        let leftTokens = Set(
            tokenize(leftSkill.name) +
            tokenize(leftSkill.description) +
            tokenize(leftSkill.body)
        )
        let rightTokens = Set(
            tokenize(rightSkill.name) +
            tokenize(rightSkill.description) +
            tokenize(rightSkill.body)
        )
        return leftTokens.filter { rightTokens.contains($0) }.count
    }

    static func findDuplicateSkillPairs(
        in skills: [TeachingSkill],
        minimumOverlapScore: Int = 3
    ) -> [DuplicateSkillPair] {
        let eligibleSkills = skills.filter { skill in
            !skill.isPinned && skill.status != .archived
        }

        var duplicatePairs: [DuplicateSkillPair] = []

        for leftIndex in 0..<eligibleSkills.count {
            for rightIndex in (leftIndex + 1)..<eligibleSkills.count {
                let leftSkill = eligibleSkills[leftIndex]
                let rightSkill = eligibleSkills[rightIndex]

                let bundleIdsOverlap = leftSkill.bundleIds.isEmpty
                    || rightSkill.bundleIds.isEmpty
                    || !Set(leftSkill.bundleIds).isDisjoint(with: rightSkill.bundleIds)
                guard bundleIdsOverlap else { continue }

                let overlapScore = tokenOverlapScore(between: leftSkill, and: rightSkill)
                guard overlapScore >= minimumOverlapScore else { continue }

                let primarySkill: TeachingSkill
                let duplicateSkill: TeachingSkill
                if leftSkill.usageCount != rightSkill.usageCount {
                    if leftSkill.usageCount > rightSkill.usageCount {
                        primarySkill = leftSkill
                        duplicateSkill = rightSkill
                    } else {
                        primarySkill = rightSkill
                        duplicateSkill = leftSkill
                    }
                } else if (leftSkill.lastUsed ?? .distantPast) >= (rightSkill.lastUsed ?? .distantPast) {
                    primarySkill = leftSkill
                    duplicateSkill = rightSkill
                } else {
                    primarySkill = rightSkill
                    duplicateSkill = leftSkill
                }

                duplicatePairs.append(
                    DuplicateSkillPair(
                        primarySkill: primarySkill,
                        duplicateSkill: duplicateSkill,
                        overlapScore: overlapScore
                    )
                )
            }
        }

        return duplicatePairs
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
