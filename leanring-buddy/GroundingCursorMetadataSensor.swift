//
//  GroundingCursorMetadataSensor.swift
//  leanring-buddy
//
//  Validates Vision-selected dot coordinates against semantic target metadata.
//  This sensor can confirm or contradict Vision, but cannot create a point.
//

enum GroundingCursorMetadataSensor {
    static func signal(
        guidePoint: SpiderGuidePoint,
        projection: GroundingPointProjection?,
        grounding: SpiderGuideSemanticGrounding?,
        target: SpiderGuideSemanticTarget?,
        element: SpiderGuideSceneGraphElement?,
        targetFingerprint: TargetFingerprint?,
        regionQuality: RegionQuality,
        screenChanged: Bool,
        policy: GroundingSensorFusionPolicy
    ) -> GroundingAuxiliarySignal {
        guard let projection else {
            return .contradicted(.cursorMetadata, [.pointOutsideScreenshot])
        }
        guard let grounding,
              let target else {
            return .contradicted(.cursorMetadata, [.visionTargetMissing])
        }

        var contradictions: [GroundingSensorFusionContradiction] = []
        let screenshotPoint = projection.screenshotPoint

        if let region = target.region {
            if !region.contains(screenshotPoint, tolerance: policy.pointRegionTolerancePixels) {
                contradictions.append(.pointOutsideTargetRegion)
            }
        } else {
            contradictions.append(.targetRegionMissing)
        }

        if target.targetConfidence != .high {
            contradictions.append(.targetConfidenceLow)
        }
        if !["click", "select"].contains(target.affordance.lowercased()) {
            contradictions.append(.targetAffordanceNotClickable)
        }
        if ["stale", "changed"].contains(target.targetStability.lowercased()) {
            contradictions.append(.targetStaleAfterScreenChange)
        }
        if screenChanged && target.targetStability.lowercased() == "unknown" {
            contradictions.append(.targetStaleAfterScreenChange)
        }
        if screenChanged && targetFingerprint == nil {
            contradictions.append(.targetFingerprintMissing)
        }
        if regionQuality.regionConfidence == .low {
            contradictions.append(.regionConfidenceLow)
        }
        if regionQuality.regionPlausibility != .plausible {
            contradictions.append(.regionImplausible)
        }
        if regionQuality.pointInsideRegionConfidence == .low {
            contradictions.append(.pointOutsideTargetRegion)
        }
        if element?.occluded == true {
            contradictions.append(.targetOccluded)
        }
        if grounding.blockedTargets.contains(where: { blockedTarget in
            guard let blockedRegion = blockedTarget.region else { return false }
            return blockedRegion.contains(screenshotPoint, tolerance: policy.blockedTargetOverlapTolerancePixels)
        }) {
            contradictions.append(.blockedTargetOverlap)
        }

        if !contradictions.isEmpty {
            return .contradicted(.cursorMetadata, contradictions)
        }
        return .confirmed(.cursorMetadata)
    }
}
