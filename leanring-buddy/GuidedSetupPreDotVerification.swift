//
//  GuidedSetupPreDotVerification.swift
//  leanring-buddy
//
//  Pre-dot verification state transitions for GuidedSetupSession. This keeps
//  the session's main file focused on session state and outcome recording.
//

import Foundation

extension GuidedSetupSession {
    mutating func resolvePreDotVerification(
        response: SpiderGuideResponse,
        sensorFusionDecision: GroundingSensorFusionDecision,
        screenSignature: String,
        screenChanged: Bool,
        pollIndex: Int?,
        policy: GroundingSensorFusionPolicy = .default,
        now: Date = Date()
    ) -> PreDotVerificationDecision {
        if let pendingPreDotVerification {
            let targetReappeared = Self.targetMatchesPendingPreDot(
                response: response,
                decision: sensorFusionDecision,
                pending: pendingPreDotVerification
            )
            let regionStillUsable = Self.regionCanCarryDot(sensorFusionDecision.evidence.regionQuality)
            let preDotLatencyMs = max(
                0,
                Int(now.timeIntervalSince(pendingPreDotVerification.requestedAt) * 1000)
            )
            let expiredByTime = preDotLatencyMs > policy.preDotVerificationMaxMs
            let expiredByPoll = (pollIndex ?? pendingPreDotVerification.pollIndex ?? 0)
                > ((pendingPreDotVerification.pollIndex ?? 0) + 2)
            let expired = expiredByTime || expiredByPoll

            if !sensorFusionDecision.shouldBlockPoint,
               !expired,
               targetReappeared,
               regionStillUsable {
                self.pendingPreDotVerification = nil
                return PreDotVerificationDecision(status: .confirmed, reason: nil, latencyMs: preDotLatencyMs)
            }

            self.pendingPreDotVerification = nil
            let rejectionReason: SpiderGuidePointRejectionReason = expired
                ? .preDotVerificationTimeout
                : .preDotVerificationFailed
            rememberNegativeTarget(
                response: response,
                sensorFusionDecision: sensorFusionDecision,
                screenSignature: screenSignature,
                reason: expired ? .preDotVerificationTimeout : .preDotVerificationFailed,
                pollIndex: pollIndex,
                now: now
            )
            return PreDotVerificationDecision(status: .failed, reason: rejectionReason, latencyMs: preDotLatencyMs)
        }

        guard sensorFusionDecision.requiresPreDotVerification else {
            return PreDotVerificationDecision(status: .notRequired, reason: nil)
        }

        pendingPreDotVerification = PendingPreDotVerification(
            targetElementIdHash: sensorFusionDecision.evidence.targetElementIdHash,
            targetFingerprint: sensorFusionDecision.evidence.targetFingerprint,
            regionQuality: sensorFusionDecision.evidence.regionQuality,
            actionRisk: sensorFusionDecision.evidence.actionRisk,
            screenType: sensorFusionDecision.evidence.screenType,
            stageType: sensorFusionDecision.evidence.stageType,
            expectedOutcome: response.point?.expectedOutcome ?? .unknown,
            semanticSignature: response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            screenSignature: screenSignature.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            requestedAt: now,
            pollIndex: pollIndex,
            reasons: sensorFusionDecision.evidence.preDotVerificationReasons
        )
        return PreDotVerificationDecision(status: .pending, reason: .preDotVerificationPending, latencyMs: 0)
    }

    private static func targetMatchesPendingPreDot(
        response: SpiderGuideResponse,
        decision: GroundingSensorFusionDecision,
        pending: PendingPreDotVerification
    ) -> Bool {
        if let pendingElementHash = pending.targetElementIdHash,
           pendingElementHash == decision.evidence.targetElementIdHash {
            return true
        }
        if let pendingFingerprint = pending.targetFingerprint,
           let currentFingerprint = decision.evidence.targetFingerprint,
           pendingFingerprint.isCompatible(with: currentFingerprint) {
            return true
        }

        guard let point = response.point,
              let target = response.semanticGrounding?.target(matching: point),
              let currentFingerprint = TargetFingerprint.make(
                  target: target,
                  grounding: response.semanticGrounding,
                  stageId: response.stageId,
                  expectedOutcome: pending.expectedOutcome
              ) else {
            return false
        }
        return pending.targetFingerprint?.isCompatible(with: currentFingerprint) == true
    }

    private static func regionCanCarryDot(_ regionQuality: RegionQuality) -> Bool {
        regionQuality.regionPlausibility == .plausible
            && regionQuality.regionConfidence != .low
            && regionQuality.pointInsideRegionConfidence != .low
            && regionQuality.regionStability != .stale
    }
}
