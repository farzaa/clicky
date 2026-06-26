//
//  GroundingTargetIdentity.swift
//  leanring-buddy
//
//  Stable, privacy-preserving target identity helpers used by sensor fusion.
//

import CoreGraphics
import Foundation

extension RegionStability {
    init(targetStability: String) {
        switch targetStability.lowercased() {
        case "new":
            self = .new
        case "stable":
            self = .stable
        case "changed", "shifted":
            self = .shifted
        case "stale":
            self = .stale
        default:
            self = .unknown
        }
    }
}

extension TargetFingerprint {
    static func make(
        target: SpiderGuideSemanticTarget?,
        grounding: SpiderGuideSemanticGrounding?,
        stageId: String?,
        expectedOutcome: SpiderGuideExpectedOutcome
    ) -> TargetFingerprint? {
        guard let target else { return nil }

        let role = normalizedComponent(target.role, fallback: "unknown_role")
        let container = normalizedComponent(target.container, fallback: "unknown_container")
        let state = normalizedComponent(target.state, fallback: "unknown_state")
        let affordance = normalizedComponent(target.affordance, fallback: "unknown_affordance")
        let stage = normalizedComponent(stageId, fallback: "unknown_stage")
        let semanticSignature = normalizedComponent(grounding?.semanticSignature, fallback: "none")
        let regionClass = regionClass(for: target.region)
        let targetElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: target.elementId) ?? "none"
        let neighborHashes = neighborHashes(for: target, grounding: grounding)

        let compatibilityComponents = [
            "role:\(role)",
            "container:\(container)",
            "state:\(state)",
            "affordance:\(affordance)",
            "regionClass:\(regionClass)",
            "stage:\(stage)",
            "expectedOutcome:\(expectedOutcome.rawValue)",
            "neighborHashes:\(neighborHashes.joined(separator: ","))",
        ]
        let strongComponents = compatibilityComponents + [
            "semanticSignature:\(semanticSignature)",
            "targetElementIdHash:\(targetElementIdHash)",
        ]

        guard let value = SpiderGroundingPrivacy.targetFingerprintHash(for: strongComponents),
              let compatibilityValue = SpiderGroundingPrivacy.targetFingerprintHash(for: compatibilityComponents) else {
            return nil
        }

        return TargetFingerprint(value: value, compatibilityValue: compatibilityValue)
    }

    private static func neighborHashes(
        for target: SpiderGuideSemanticTarget,
        grounding: SpiderGuideSemanticGrounding?
    ) -> [String] {
        (grounding?.interactiveTargets ?? [])
            .filter { neighbor in
                guard neighbor.elementId != nil || target.elementId != nil else { return neighbor.region != target.region }
                return neighbor.elementId != target.elementId
            }
            .prefix(6)
            .compactMap { neighbor in
                SpiderGroundingPrivacy.targetFingerprintHash(for: [
                    "role:\(normalizedComponent(neighbor.role, fallback: "unknown_role"))",
                    "container:\(normalizedComponent(neighbor.container, fallback: "unknown_container"))",
                    "state:\(normalizedComponent(neighbor.state, fallback: "unknown_state"))",
                    "affordance:\(normalizedComponent(neighbor.affordance, fallback: "unknown_affordance"))",
                    "regionClass:\(regionClass(for: neighbor.region))",
                ])
            }
            .sorted()
            .prefix(3)
            .map { $0 }
    }

    private static func regionClass(for region: SpiderGuideRegion?) -> String {
        guard let region,
              region.width.isFinite,
              region.height.isFinite,
              region.width > 0,
              region.height > 0 else {
            return "missing"
        }

        let widthClass = dimensionClass(region.width)
        let heightClass = dimensionClass(region.height)
        let ratio = region.width / max(region.height, 1)
        let shape: String
        if ratio >= 2.2 {
            shape = "wide"
        } else if ratio <= 0.45 {
            shape = "tall"
        } else {
            shape = "balanced"
        }
        let areaClass = areaClass(region.width * region.height)
        return "w:\(widthClass):h:\(heightClass):shape:\(shape):area:\(areaClass)"
    }

    private static func dimensionClass(_ value: Double) -> String {
        switch value {
        case ..<48:
            return "xs"
        case ..<120:
            return "sm"
        case ..<280:
            return "md"
        case ..<560:
            return "lg"
        default:
            return "xl"
        }
    }

    private static func areaClass(_ value: Double) -> String {
        switch value {
        case ..<2_500:
            return "xs"
        case ..<14_000:
            return "sm"
        case ..<60_000:
            return "md"
        case ..<200_000:
            return "lg"
        default:
            return "xl"
        }
    }

    private static func normalizedComponent(_ value: String?, fallback: String) -> String {
        let sanitizedValue = value?.spiderSanitizedSingleLine(maxCharacters: 96).lowercased() ?? ""
        return sanitizedValue.isEmpty ? fallback : sanitizedValue
    }
}

extension SpiderGuideSemanticGrounding {
    func target(matching point: SpiderGuidePoint) -> SpiderGuideSemanticTarget? {
        if let targetElementId = point.targetElementId,
           let target = interactiveTargets.first(where: { $0.elementId == targetElementId }) {
            return target
        }

        let screenshotPoint = CGPoint(x: point.x, y: point.y)
        return interactiveTargets.first { target in
            target.region?.contains(screenshotPoint, tolerance: GroundingSensorFusionPolicy.default.pointRegionTolerancePixels) == true
        }
    }

    func element(matching target: SpiderGuideSemanticTarget?) -> SpiderGuideSceneGraphElement? {
        guard let elementId = target?.elementId else { return nil }
        return elements.first(where: { $0.id == elementId })
    }
}
