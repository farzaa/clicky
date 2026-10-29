//
//  SkillTargetAppResolver.swift
//  leanring-buddy
//
//  Resolves which app a tutoring session is teaching, which may differ from the
//  frontmost app (e.g. terminal focused while TextEdit is visible on screen).
//

import Foundation

enum SkillTargetAppResolver {
    static func resolveTargetBundleId(
        from sessionTrace: [SessionTraceEntry],
        frontmostBundleId: String?,
        existingSkill: TeachingSkill? = nil
    ) -> String? {
        if let primaryQuestion = SkillTriggerEvaluator.primaryTeachingQuestion(from: sessionTrace),
           let bundleIdFromPrimaryQuestion = TeachingSkill.detectBundleId(in: primaryQuestion) {
            return bundleIdFromPrimaryQuestion
        }

        for entry in sessionTrace {
            for text in [entry.userTranscript, entry.assistantResponse] {
                if let bundleId = TeachingSkill.detectBundleId(in: text) {
                    return bundleId
                }
            }
        }

        if let existingSkill, let existingBundleId = existingSkill.bundleIds.first {
            return existingBundleId
        }

        return frontmostBundleId
    }
}
