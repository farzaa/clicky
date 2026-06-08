//
//  MemoryGate.swift
//  leanring-buddy
//
//  Cheap cold-path rules deciding whether a persisted session is worth
//  distilling and into which memory categories. No LLM.
//

import Foundation

enum MemoryCategory: String, Codable, CaseIterable {
    case skill
    case preference
    case routine
}

enum GateReason: String, Codable, Equatable {
    case userConfirmed
    case multiStepPointing
    case repeatedTopic
    case screenTeaching
}

enum BlockReason: String, Codable, Equatable {
    case privacyOptOut
    case abandonedWithoutConfirmation
    case genericOffScreenQA
    case learningDisabled
    case empty
}

struct MemoryGateDecision: Equatable {
    let sessionId: UUID
    let passedCategories: [MemoryCategory: [GateReason]]
    let blockReasons: [BlockReason]

    func passes(_ category: MemoryCategory) -> Bool {
        passedCategories[category] != nil
    }

    var shouldDistillSkill: Bool {
        passes(.skill)
    }
}

enum MemoryGate {
    static func evaluate(
        session: PersistedSession,
        topicHistory: [TeachingTopicHistoryEntry],
        isLearningEnabled: Bool,
        now: Date = Date()
    ) -> MemoryGateDecision {
        guard isLearningEnabled else {
            return blockedDecision(sessionId: session.sessionId, reason: .learningDisabled)
        }

        guard !session.privacyOptOut else {
            return blockedDecision(sessionId: session.sessionId, reason: .privacyOptOut)
        }

        guard !session.turns.isEmpty else {
            return blockedDecision(sessionId: session.sessionId, reason: .empty)
        }

        guard SkillTriggerEvaluator.isScreenTeachingSession(session.turns) else {
            return blockedDecision(sessionId: session.sessionId, reason: .genericOffScreenQA)
        }

        let hasConfirmationOnAnyTurn = session.turns.contains {
            SkillTriggerEvaluator.isConfirmationTranscript($0.userTranscript)
        }

        if session.outcome == .abandoned && !hasConfirmationOnAnyTurn {
            return blockedDecision(sessionId: session.sessionId, reason: .abandonedWithoutConfirmation)
        }

        var skillReasons: [GateReason] = []

        if let lastTurn = session.turns.last,
           SkillTriggerEvaluator.isConfirmationTranscript(lastTurn.userTranscript) {
            skillReasons.append(.userConfirmed)
        }

        if session.turns.filter(\.pointed).count >= 2 {
            skillReasons.append(.multiStepPointing)
        }

        skillReasons.append(.screenTeaching)

        let topic = SkillTriggerEvaluator.deriveTopic(from: session.turns)
        let resolvedBundleId = SkillTargetAppResolver.resolveTargetBundleId(
            from: session.turns,
            frontmostBundleId: session.turns.last?.bundleId
        )

        if TeachingTopicHistoryStore.hasRepeatedTopic(
            topic: topic,
            bundleId: resolvedBundleId,
            withinDays: 7,
            in: topicHistory,
            now: now
        ) {
            skillReasons.append(.repeatedTopic)
        }

        guard !skillReasons.isEmpty else {
            return blockedDecision(sessionId: session.sessionId, reason: .genericOffScreenQA)
        }

        return MemoryGateDecision(
            sessionId: session.sessionId,
            passedCategories: [.skill: skillReasons],
            blockReasons: []
        )
    }

    static func makeSkillWriteTrigger(
        for session: PersistedSession,
        gateReasons: [GateReason]
    ) -> SkillWriteTrigger {
        let primaryGateReason = gateReasons.first ?? .screenTeaching
        let skillReason = SkillWriteTrigger.Reason(rawValue: primaryGateReason.rawValue) ?? .screenTeaching
        let topic = SkillTriggerEvaluator.deriveTopic(from: session.turns)
        return SkillWriteTrigger(reason: skillReason, topic: topic)
    }

    private static func blockedDecision(sessionId: UUID, reason: BlockReason) -> MemoryGateDecision {
        MemoryGateDecision(
            sessionId: sessionId,
            passedCategories: [:],
            blockReasons: [reason]
        )
    }
}
