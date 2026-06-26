//
//  GroundingSensorFusionDecisionResolver.swift
//  leanring-buddy
//
//  Pure decision policy for turning sensor-fusion evidence into a dot verdict.
//

import Foundation

enum GroundingSensorFusionDecisionResolver {
    static func resolve(
        from evidence: GroundingSensorFusionEvidence,
        policy: GroundingSensorFusionPolicy
    ) -> GroundingSensorFusionDecision {
        let signalContradictions = evidence.signals.flatMap(\.contradictionReasons)
        let allContradictions = signalContradictions + evidence.policyContradictions
        let ocrOnlyContradiction = !allContradictions.isEmpty
            && Set(allContradictions.map(\.rawValue)) == Set([GroundingSensorFusionContradiction.ocrTextMismatch.rawValue])
            && evidence.calibrationDecision == .downgradedOCROnlyContradiction
        let hasContradiction = !allContradictions.isEmpty && !ocrOnlyContradiction
        let confirmedCount = evidence.signals.filter { $0.result == .confirmed }.count
        let weaklyConfirmedCount = evidence.signals.filter { $0.result == .weaklyConfirmed }.count
        let unavailableCount = evidence.signals.filter { $0.result == .unavailable }.count

        let finalDecision: GroundingSensorFusionDecisionKind
        if evidence.calibrationDecision == .strongBlock {
            finalDecision = .contradicted
        } else if hasContradiction {
            finalDecision = .contradicted
        } else if confirmedCount >= 2 {
            finalDecision = .confirmed
        } else if confirmedCount + weaklyConfirmedCount > 0 {
            finalDecision = .weaklyConfirmed
        } else if unavailableCount == evidence.signals.count {
            finalDecision = .unavailable
        } else {
            finalDecision = .inconclusive
        }

        let shouldBlockPoint = policy.blockOnStrongContradiction
            && (finalDecision == .contradicted
                || evidence.calibrationDecision == .strongBlock
                || evidence.dotSuppressedByLatency)
        return GroundingSensorFusionDecision(
            evidence: evidence,
            finalDecision: finalDecision,
            shouldBlockPoint: shouldBlockPoint,
            userFacingReason: ""
        )
    }
}
