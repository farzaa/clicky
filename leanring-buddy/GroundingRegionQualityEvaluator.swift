//
//  GroundingRegionQualityEvaluator.swift
//  leanring-buddy
//
//  Scores the geometric quality of a Vision target region before the dot can
//  use it as evidence.
//

import CoreGraphics

enum GroundingRegionQualityEvaluator {
    static func evaluate(
        guidePoint: SpiderGuidePoint,
        projection: GroundingPointProjection?,
        grounding: SpiderGuideSemanticGrounding?,
        target: SpiderGuideSemanticTarget?,
        element: SpiderGuideSceneGraphElement?,
        policy: GroundingSensorFusionPolicy
    ) -> RegionQuality {
        guard let target,
              let targetRegion = target.region else {
            return .unavailable
        }

        let screenshotPoint = projection?.screenshotPoint ?? CGPoint(x: guidePoint.x, y: guidePoint.y)
        let regionStability = RegionStability(targetStability: target.targetStability)
        let pointInsideRegionConfidence: RegionConfidence
        if targetRegion.contains(screenshotPoint) {
            pointInsideRegionConfidence = .high
        } else if targetRegion.contains(screenshotPoint, tolerance: policy.pointRegionTolerancePixels) {
            pointInsideRegionConfidence = .medium
        } else {
            pointInsideRegionConfidence = .low
        }

        let plausibility: RegionPlausibility = {
            guard targetRegion.width.isFinite,
                  targetRegion.height.isFinite,
                  targetRegion.width >= 4,
                  targetRegion.height >= 4 else {
                return .tooSmall
            }

            if let projection {
                let screenshotWidth = Double(projection.capture.screenshotWidthInPixels)
                let screenshotHeight = Double(projection.capture.screenshotHeightInPixels)
                let screenshotArea = screenshotWidth * screenshotHeight
                let targetArea = max(0, targetRegion.width) * max(0, targetRegion.height)
                let screenshotBounds = CGRect(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight)
                if !screenshotBounds.contains(targetRegion.rect) {
                    return .outsideScreenshot
                }
                if screenshotArea > 0 && targetArea / screenshotArea > 0.9 {
                    return .tooLarge
                }
            }

            if let elementRegion = element?.region,
               targetRegion.overlapRatio(with: elementRegion) < 0.5 {
                return .elementMismatch
            }

            if grounding?.blockedTargets.contains(where: { blockedTarget in
                guard let blockedRegion = blockedTarget.region else { return false }
                return blockedRegion.contains(
                    screenshotPoint,
                    tolerance: policy.blockedTargetOverlapTolerancePixels
                )
            }) == true {
                return .blockedOverlap
            }

            return .plausible
        }()

        let source: RegionSource
        if element?.region != nil {
            source = plausibility == .elementMismatch ? .vision : .visionAndElement
        } else {
            source = .vision
        }

        let confidence: RegionConfidence
        if plausibility != .plausible || pointInsideRegionConfidence == .low {
            confidence = .low
        } else if target.targetConfidence == .high,
                  element?.confidence != .low,
                  pointInsideRegionConfidence == .high {
            confidence = .high
        } else {
            confidence = .medium
        }

        return RegionQuality(
            regionConfidence: confidence,
            regionSource: source,
            regionStability: regionStability,
            regionPlausibility: plausibility,
            pointInsideRegionConfidence: pointInsideRegionConfidence
        )
    }
}
