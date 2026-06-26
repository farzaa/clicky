//
//  SpiderGuideGroundingContracts.swift
//  leanring-buddy
//
//  Geometry and semantic grounding contracts returned by the Worker guide
//  response. These contracts are ephemeral and must not be persisted as raw
//  screen content.
//

import CoreGraphics
import Foundation

struct SpiderGuidePoint: Codable, Equatable {
    let x: Double
    let y: Double
    let label: String?
    let screenNumber: Int?
    let missionAlignment: String?
    let targetElementId: String?
    let expectedOutcome: SpiderGuideExpectedOutcome
}

struct SpiderGuideRegion: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func contains(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func intersects(_ other: SpiderGuideRegion) -> Bool {
        rect.intersects(other.rect)
    }

    func overlapRatio(with other: SpiderGuideRegion) -> CGFloat {
        let intersection = rect.intersection(other.rect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let smallerArea = min(rect.width * rect.height, other.rect.width * other.rect.height)
        guard smallerArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / smallerArea
    }
}

struct TargetFingerprint: Codable, Equatable {
    let value: String
    let compatibilityValue: String

    func isCompatible(with other: TargetFingerprint) -> Bool {
        value == other.value || compatibilityValue == other.compatibilityValue
    }
}

struct GroundingRevision: Codable, Equatable {
    let screenSignature: String
    let semanticSignature: String?
    let groundingRevision: String?
    let observedAt: Date
    let pollIndex: Int?
}

enum RegionConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum RegionSource: String, Codable, Equatable {
    case vision
    case visionAndElement = "vision_and_element"
    case unavailable
}

enum RegionStability: String, Codable, Equatable {
    case new
    case stable
    case shifted
    case stale
    case unknown
}

enum RegionPlausibility: String, Codable, Equatable {
    case plausible
    case missing
    case tooSmall = "too_small"
    case tooLarge = "too_large"
    case outsideScreenshot = "outside_screenshot"
    case elementMismatch = "element_mismatch"
    case blockedOverlap = "blocked_overlap"
}

struct RegionQuality: Codable, Equatable {
    let regionConfidence: RegionConfidence
    let regionSource: RegionSource
    let regionStability: RegionStability
    let regionPlausibility: RegionPlausibility
    let pointInsideRegionConfidence: RegionConfidence

    static let unavailable = RegionQuality(
        regionConfidence: .low,
        regionSource: .unavailable,
        regionStability: .unknown,
        regionPlausibility: .missing,
        pointInsideRegionConfidence: .low
    )
}

struct SpiderGuideSceneGraphElement: Codable, Equatable {
    let id: String
    let label: String
    let role: String
    let containerId: String?
    let parentId: String?
    let zIndexHint: String
    let occluded: Bool
    let region: SpiderGuideRegion?
    let confidence: SpiderGuideConfidence
    let evidence: [String]
}

struct SpiderGuideSemanticTarget: Codable, Equatable {
    let elementId: String?
    let label: String
    let role: String
    let container: String
    let parentLabel: String?
    let nearestText: [String]
    let semanticIntent: String
    let state: String
    let risk: String
    let targetConfidence: SpiderGuideConfidence
    let evidence: [String]
    let affordance: String
    let targetStability: String
    let region: SpiderGuideRegion?
}

struct SpiderGuideSemanticGrounding: Codable, Equatable {
    let groundingRevision: String?
    let semanticSignature: String?

    // Current-pixel scene graph from the Worker/Vision response. The app keeps
    // this ephemeral and never persists the labels/evidence.
    let elements: [SpiderGuideSceneGraphElement]
    let visibleConcepts: [String]
    let interactiveTargets: [SpiderGuideSemanticTarget]
    let blockedTargets: [SpiderGuideSemanticTarget]
    let uncertainty: [String]

    enum CodingKeys: String, CodingKey {
        case groundingRevision
        case semanticSignature
        case elements
        case visibleConcepts
        case interactiveTargets
        case blockedTargets
        case uncertainty
    }

    init(
        groundingRevision: String?,
        semanticSignature: String?,
        elements: [SpiderGuideSceneGraphElement] = [],
        visibleConcepts: [String] = [],
        interactiveTargets: [SpiderGuideSemanticTarget] = [],
        blockedTargets: [SpiderGuideSemanticTarget] = [],
        uncertainty: [String] = []
    ) {
        self.groundingRevision = groundingRevision
        self.semanticSignature = semanticSignature
        self.elements = elements
        self.visibleConcepts = visibleConcepts
        self.interactiveTargets = interactiveTargets
        self.blockedTargets = blockedTargets
        self.uncertainty = uncertainty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groundingRevision = try container.decodeIfPresent(String.self, forKey: .groundingRevision)
        self.semanticSignature = try container.decodeIfPresent(String.self, forKey: .semanticSignature)
        self.elements = try container.decodeIfPresent([SpiderGuideSceneGraphElement].self, forKey: .elements) ?? []
        self.visibleConcepts = try container.decodeIfPresent([String].self, forKey: .visibleConcepts) ?? []
        self.interactiveTargets = try container.decodeIfPresent(
            [SpiderGuideSemanticTarget].self,
            forKey: .interactiveTargets
        ) ?? []
        self.blockedTargets = try container.decodeIfPresent(
            [SpiderGuideSemanticTarget].self,
            forKey: .blockedTargets
        ) ?? []
        self.uncertainty = try container.decodeIfPresent([String].self, forKey: .uncertainty) ?? []
    }
}
