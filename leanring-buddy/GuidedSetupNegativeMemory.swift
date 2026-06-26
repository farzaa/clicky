//
//  GuidedSetupNegativeMemory.swift
//  leanring-buddy
//
//  Short-lived memory for targets that should not receive the dot again until
//  the screen evidence changes.
//

import Foundation

extension GuidedSetupSession {
    func shouldRejectNegativeMemory(_ response: SpiderGuideResponse, now: Date = Date()) -> Bool {
        guard let point = response.point else {
            return false
        }
        let currentStageId = response.stageId?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        ) ?? ""
        let currentSemanticSignature = response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
        )
        let currentElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: point.targetElementId)
        let currentFingerprint = response.semanticGrounding?.target(matching: point).flatMap {
            TargetFingerprint.make(
                target: $0,
                grounding: response.semanticGrounding,
                stageId: response.stageId,
                expectedOutcome: point.expectedOutcome
            )
        }

        return negativeMemories.contains { memory in
            guard memory.expiresAt > now else { return false }
            guard memory.stageId.isEmpty || currentStageId.isEmpty || memory.stageId == currentStageId else {
                return false
            }
            if let memorySemanticSignature = memory.semanticSignature,
               let currentSemanticSignature,
               memorySemanticSignature != currentSemanticSignature {
                return false
            }
            if let memoryElementHash = memory.targetElementIdHash,
               memoryElementHash == currentElementIdHash {
                return true
            }
            if let memoryFingerprint = memory.targetFingerprint,
               let currentFingerprint {
                return memoryFingerprint.isCompatible(with: currentFingerprint)
            }
            return memory.targetElementIdHash == nil && memory.targetFingerprint == nil && currentElementIdHash == nil
        }
    }

    mutating func rememberNegativeTarget(
        response: SpiderGuideResponse,
        sensorFusionDecision: GroundingSensorFusionDecision?,
        screenSignature: String?,
        reason: GroundingNegativeMemoryReason,
        pollIndex: Int?,
        now: Date = Date()
    ) {
        purgeExpiredNegativeMemories(now: now)

        let targetFingerprint = sensorFusionDecision?.evidence.targetFingerprint ?? response.point.flatMap { point in
            response.semanticGrounding?.target(matching: point).flatMap {
                TargetFingerprint.make(
                    target: $0,
                    grounding: response.semanticGrounding,
                    stageId: response.stageId,
                    expectedOutcome: point.expectedOutcome
                )
            }
        }
        let targetElementIdHash = sensorFusionDecision?.evidence.targetElementIdHash
            ?? SpiderGroundingPrivacy.targetElementIdHash(for: response.point?.targetElementId)
        let semanticSignature = response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
        )
        let stageId = response.stageId?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        ) ?? currentStageId

        let entry = GroundingNegativeMemoryEntry(
            targetElementIdHash: targetElementIdHash,
            targetFingerprint: targetFingerprint,
            semanticSignature: semanticSignature,
            screenSignature: screenSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            stageId: stageId,
            reason: reason,
            createdAt: now,
            expiresAt: now.addingTimeInterval(90),
            pollIndex: pollIndex
        )

        negativeMemories.removeAll { existing in
            existing.reason == entry.reason
                && existing.stageId == entry.stageId
                && existing.semanticSignature == entry.semanticSignature
                && existing.targetElementIdHash == entry.targetElementIdHash
                && existing.targetFingerprint == entry.targetFingerprint
        }
        appendNegativeMemory(entry)
    }

    mutating func rememberNegativeOutcome(
        _ pendingPointOutcome: PendingGuidePointOutcome,
        reason: GroundingNegativeMemoryReason,
        now: Date = Date()
    ) {
        purgeExpiredNegativeMemories(now: now)
        appendNegativeMemory(
            GroundingNegativeMemoryEntry(
                targetElementIdHash: pendingPointOutcome.targetElementIdHash,
                targetFingerprint: pendingPointOutcome.targetFingerprint,
                semanticSignature: pendingPointOutcome.semanticSignature,
                screenSignature: pendingPointOutcome.groundingRevision?.screenSignature,
                stageId: pendingPointOutcome.stageId,
                reason: reason,
                createdAt: now,
                expiresAt: now.addingTimeInterval(90),
                pollIndex: pendingPointOutcome.groundingRevision?.pollIndex
            )
        )
    }

    private mutating func appendNegativeMemory(_ entry: GroundingNegativeMemoryEntry) {
        negativeMemories.append(entry)
        if negativeMemories.count > 24 {
            negativeMemories.removeFirst(negativeMemories.count - 24)
        }
    }

    private mutating func purgeExpiredNegativeMemories(now: Date) {
        negativeMemories.removeAll { $0.expiresAt <= now }
    }
}
