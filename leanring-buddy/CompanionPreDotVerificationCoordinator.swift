//
//  CompanionPreDotVerificationCoordinator.swift
//  leanring-buddy
//
//  Coordinates the pre-dot verification boundary for a guide response. The
//  session owns the ephemeral state; this type only keeps CompanionManager out
//  of the mutation details.
//

import Foundation

struct CompanionPreDotVerificationResolution {
    let guidedSetupSession: GuidedSetupSession?
    let rejectionReason: SpiderGuidePointRejectionReason?
    let latencyMs: Int?
    let didFailVerification: Bool
}

enum CompanionPreDotVerificationCoordinator {
    static func resolve(
        guideResponse: SpiderGuideResponse,
        sensorFusionDecision: GroundingSensorFusionDecision?,
        pointWasEvaluated: Bool,
        guidedSetupSession: GuidedSetupSession?,
        screenSignature: String,
        screenChanged: Bool,
        pollIndex: Int?,
        policy: GroundingSensorFusionPolicy = .default,
        now: Date = Date()
    ) -> CompanionPreDotVerificationResolution {
        guard let decision = sensorFusionDecision,
              pointWasEvaluated else {
            return unchanged(guidedSetupSession)
        }

        if decision.shouldBlockPoint {
            guard var session = guidedSetupSession else {
                return unchanged(nil)
            }
            session.rememberNegativeTarget(
                response: guideResponse,
                sensorFusionDecision: decision,
                screenSignature: screenSignature,
                reason: SpiderGuidePointSafetyPolicy.negativeMemoryReason(for: decision),
                pollIndex: pollIndex,
                now: now
            )
            return CompanionPreDotVerificationResolution(
                guidedSetupSession: session,
                rejectionReason: nil,
                latencyMs: nil,
                didFailVerification: false
            )
        }

        guard decision.requiresPreDotVerification
                || guidedSetupSession?.pendingPreDotVerification != nil else {
            return unchanged(guidedSetupSession)
        }

        guard var session = guidedSetupSession else {
            return CompanionPreDotVerificationResolution(
                guidedSetupSession: nil,
                rejectionReason: decision.requiresPreDotVerification ? .preDotVerificationPending : nil,
                latencyMs: nil,
                didFailVerification: false
            )
        }

        let preDotDecision = session.resolvePreDotVerification(
            response: guideResponse,
            sensorFusionDecision: decision,
            screenSignature: screenSignature,
            screenChanged: screenChanged,
            pollIndex: pollIndex,
            policy: policy,
            now: now
        )
        return CompanionPreDotVerificationResolution(
            guidedSetupSession: session,
            rejectionReason: preDotDecision.reason,
            latencyMs: preDotDecision.latencyMs,
            didFailVerification: preDotDecision.status == .failed
        )
    }

    private static func unchanged(
        _ guidedSetupSession: GuidedSetupSession?
    ) -> CompanionPreDotVerificationResolution {
        CompanionPreDotVerificationResolution(
            guidedSetupSession: guidedSetupSession,
            rejectionReason: nil,
            latencyMs: nil,
            didFailVerification: false
        )
    }
}
