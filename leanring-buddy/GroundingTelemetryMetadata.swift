//
//  GroundingTelemetryMetadata.swift
//  leanring-buddy
//
//  Privacy-safe metadata contracts and construction for grounding telemetry.
//  These values are intentionally small, typed, and free of screen content.
//

import Foundation

struct GroundingGuideResponseMetadata: Equatable {
    let platform: SpiderAdPlatformID
    let stageId: String?
    let screenState: SpiderGuideScreenState
    let screenConfidence: SpiderGuideConfidence
    let semanticSignature: String?
}

struct GroundingPointRejectionMetadata: Equatable {
    let stageId: String?
    let screenState: SpiderGuideScreenState?
    let screenConfidence: SpiderGuideConfidence?
    let semanticSignature: String?
    let targetElementIdHash: String?
    let expectedOutcome: SpiderGuideExpectedOutcome?
    let retryPolicy: GroundingRetryPolicy?
}

struct GroundingPointAcceptanceMetadata: Equatable {
    let targetElementIdHash: String?
    let expectedOutcome: SpiderGuideExpectedOutcome
    let targetFingerprint: TargetFingerprint?
}

enum GroundingTelemetryMetadataBuilder {
    static func guideResponseMetadata(
        platform: SpiderAdPlatformID,
        guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState
    ) -> GroundingGuideResponseMetadata {
        GroundingGuideResponseMetadata(
            platform: platform,
            stageId: guideResponse.stageId,
            screenState: resolvedScreenState,
            screenConfidence: guideResponse.screenConfidence ?? guideResponse.confidence,
            semanticSignature: guideResponse.semanticGrounding?.semanticSignature
        )
    }

    static func pointAcceptanceMetadata(
        for guidePoint: SpiderGuidePoint,
        sensorFusionDecision: GroundingSensorFusionDecision?
    ) -> GroundingPointAcceptanceMetadata {
        GroundingPointAcceptanceMetadata(
            targetElementIdHash: SpiderGroundingPrivacy.targetElementIdHash(for: guidePoint.targetElementId),
            expectedOutcome: guidePoint.expectedOutcome,
            targetFingerprint: sensorFusionDecision?.evidence.targetFingerprint
        )
    }

    static func pointRejectionMetadata(
        for guideResponse: SpiderGuideResponse?,
        resolvedScreenState: SpiderGuideScreenState?,
        retryPolicy: GroundingRetryPolicy?
    ) -> GroundingPointRejectionMetadata? {
        guard let guideResponse else { return nil }

        return GroundingPointRejectionMetadata(
            stageId: guideResponse.stageId,
            screenState: resolvedScreenState,
            screenConfidence: guideResponse.screenConfidence ?? guideResponse.confidence,
            semanticSignature: guideResponse.semanticGrounding?.semanticSignature,
            targetElementIdHash: SpiderGroundingPrivacy.targetElementIdHash(for: guideResponse.point?.targetElementId),
            expectedOutcome: guideResponse.point?.expectedOutcome,
            retryPolicy: retryPolicy
        )
    }

    static func shouldTrackShadowCandidate(for guideResponse: SpiderGuideResponse?) -> Bool {
        guideResponse?.point != nil
    }
}
