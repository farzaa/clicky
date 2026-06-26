//
//  GroundingSensorFusionContracts.swift
//  leanring-buddy
//
//  Typed contracts for the local, privacy-safe confirmation layer that guards
//  Vision-selected guide points before the Spider dot can appear.
//

import CoreGraphics
import Foundation

enum GroundingSensorFusionDecisionKind: String, Equatable {
    case confirmed
    case weaklyConfirmed = "weakly_confirmed"
    case inconclusive
    case contradicted
    case unavailable
}

enum GroundingAuxiliarySignalSource: String, CaseIterable, Equatable {
    case localOCR = "local_ocr"
    case macOSAccessibility = "macos_accessibility"
    case browserMetadata = "browser_metadata"
    case cursorMetadata = "cursor_metadata"
}

enum GroundingAuxiliarySignalResult: String, Equatable {
    case confirmed
    case weaklyConfirmed = "weakly_confirmed"
    case inconclusive
    case contradicted
    case unavailable
}

enum GroundingSensorFusionContradiction: String, Equatable {
    case pointOutsideScreenshot = "point_outside_screenshot"
    case visionTargetMissing = "vision_target_missing"
    case targetRegionMissing = "target_region_missing"
    case pointOutsideTargetRegion = "point_outside_target_region"
    case blockedTargetOverlap = "blocked_target_overlap"
    case targetConfidenceLow = "target_confidence_low"
    case targetAffordanceNotClickable = "target_affordance_not_clickable"
    case targetFingerprintMissing = "target_fingerprint_missing"
    case targetStaleAfterScreenChange = "target_stale_after_screen_change"
    case regionConfidenceLow = "region_confidence_low"
    case regionImplausible = "region_implausible"
    case targetOccluded = "target_occluded"
    case ocrTextMismatch = "ocr_text_mismatch"
    case accessibilityElementDisabled = "accessibility_element_disabled"
    case accessibilityElementNotInteractive = "accessibility_element_not_interactive"
    case browserElementDisabled = "browser_element_disabled"
    case browserElementHidden = "browser_element_hidden"
    case browserElementCovered = "browser_element_covered"
    case actionRiskBlocked = "action_risk_blocked"
    case journeyTransitionInvalid = "journey_transition_invalid"
    case calibrationStrongBlock = "calibration_strong_block"
    case latencyBudgetExceeded = "latency_budget_exceeded"
}

enum GroundingActionRisk: String, Codable, Equatable {
    case reversible
    case navigation
    case selection
    case input
    case readOnly = "read_only"
    case wait
    case spendBoundary = "spend_boundary"
    case publishBoundary = "publish_boundary"
    case billingBoundary = "billing_boundary"
    case authBoundary = "auth_boundary"
    case policyBoundary = "policy_boundary"
    case destructive
    case unknown

    var allowsDot: Bool {
        switch self {
        case .reversible, .navigation, .selection, .input:
            return true
        case .readOnly, .wait, .spendBoundary, .publishBoundary, .billingBoundary,
             .authBoundary, .policyBoundary, .destructive, .unknown:
            return false
        }
    }

    var isSensitiveBoundary: Bool {
        switch self {
        case .spendBoundary, .publishBoundary, .billingBoundary, .authBoundary, .policyBoundary, .destructive:
            return true
        case .reversible, .navigation, .selection, .input, .readOnly, .wait, .unknown:
            return false
        }
    }
}

enum GroundingScreenType: String, Codable, Equatable {
    case wizard
    case table
    case modalDialogPopover = "modal_dialog_popover"
    case cardTileSelection = "card_tile_selection"
    case form
    case dropdown
    case alertWarning = "alert_warning"
    case reviewPublishBoundary = "review_publish_boundary"
    case loadingSkeleton = "loading_skeleton"
    case unknown
}

enum GroundingStageType: String, Codable, Equatable {
    case safeSetup = "safe_setup"
    case sensitiveBoundary = "sensitive_boundary"
    case loading
    case unknown
}

enum GroundingJourneyTransitionKind: String, Codable, Equatable {
    case wizardToForm = "wizard_to_form"
    case wizardToReview = "wizard_to_review"
    case formToDropdown = "form_to_dropdown"
    case dropdownToSelection = "dropdown_to_selection"
    case tableToModal = "table_to_modal"
    case modalToForm = "modal_to_form"
    case modalToClosed = "modal_to_closed"
    case formToWarning = "form_to_warning"
    case warningToForm = "warning_to_form"
    case reviewToManualBoundary = "review_to_manual_boundary"
    case loadingToRecognized = "loading_to_recognized"
    case recognizedToLoadingToRecognized = "recognized_to_loading_to_recognized"
    case sameScreen = "same_screen"
    case invalidBoundary = "invalid_boundary"
    case unknown
}

struct GroundingJourneyDecision: Codable, Equatable {
    let transition: GroundingJourneyTransitionKind
    let allowsDot: Bool

    static let unknown = GroundingJourneyDecision(transition: .unknown, allowsDot: true)
}

enum GroundingCalibrationDecision: String, Codable, Equatable {
    case allow
    case requirePreDotVerification = "require_pre_dot_verification"
    case strongBlock = "strong_block"
    case downgradedOCROnlyContradiction = "downgraded_ocr_only_contradiction"
}

enum GroundingFastPathDecision: String, Codable, Equatable {
    case accepted
    case blocked
    case notEligible = "not_eligible"
}

enum GroundingPreDotVerificationReason: String, Codable, Equatable {
    case targetNewOrUnknown = "target_new_or_unknown"
    case screenChanged = "screen_changed"
    case regionMedium = "region_medium"
    case regionUnstable = "region_unstable"
    case overlayVisible = "overlay_visible"
    case sensitiveStage = "sensitive_stage"
    case weakFusion = "weak_fusion"
    case latencyExceeded = "latency_exceeded"
}

enum GroundingBrowserMetadataSource: String, Equatable {
    case unavailable
    case accessibilityFallback = "accessibility_fallback"
    case browserBridge = "browser_bridge"
}

enum GroundingBrowserRoleCategory: String, Equatable {
    case button
    case link
    case textField = "text_field"
    case checkbox
    case radioButton = "radio_button"
    case menu
    case menuItem = "menu_item"
    case select
    case slider
    case table
    case tab
    case other
    case unknown
}

struct GroundingSensorFusionPolicy: Equatable {
    let pointRegionTolerancePixels: CGFloat
    let blockedTargetOverlapTolerancePixels: CGFloat
    let ocrRegionPaddingPixels: CGFloat
    let ocrMinimumConfidence: Float
    let minimumOCRTokenCharacters: Int
    let ocrStrongMismatchMinimumCandidates: Int
    let ocrStrongMismatchMinimumTokenCount: Int
    let ocrStrongMismatchMinimumAverageConfidence: Float
    let maximumAXParentDepth: Int
    let localOCRLatencyCutoffMs: Int
    let accessibilityLatencyCutoffMs: Int
    let browserMetadataLatencyCutoffMs: Int
    let totalPointDecisionLatencyCutoffMs: Int
    let fastPathMaxDecisionMs: Int
    let ocrDeadlineMs: Int
    let axDeadlineMs: Int
    let browserDeadlineMs: Int
    let preDotVerificationMaxMs: Int
    let totalDecisionMaxMs: Int
    let blockOnStrongContradiction: Bool

    nonisolated static let `default` = GroundingSensorFusionPolicy(
        pointRegionTolerancePixels: 6,
        blockedTargetOverlapTolerancePixels: 6,
        ocrRegionPaddingPixels: 16,
        ocrMinimumConfidence: 0.45,
        minimumOCRTokenCharacters: 3,
        ocrStrongMismatchMinimumCandidates: 2,
        ocrStrongMismatchMinimumTokenCount: 2,
        ocrStrongMismatchMinimumAverageConfidence: 0.72,
        maximumAXParentDepth: 4,
        localOCRLatencyCutoffMs: 350,
        accessibilityLatencyCutoffMs: 180,
        browserMetadataLatencyCutoffMs: 180,
        totalPointDecisionLatencyCutoffMs: 700,
        fastPathMaxDecisionMs: 260,
        ocrDeadlineMs: 240,
        axDeadlineMs: 140,
        browserDeadlineMs: 140,
        preDotVerificationMaxMs: 1_200,
        totalDecisionMaxMs: 700,
        blockOnStrongContradiction: true
    )
}

struct GroundingBrowserMetadata: Equatable {
    let source: GroundingBrowserMetadataSource
    let isWebSurface: Bool
    let roleCategory: GroundingBrowserRoleCategory
    let elementClickable: Bool?
    let elementInteractable: Bool?
    let elementDisabled: Bool?
    let elementHidden: Bool?
    let elementCovered: Bool?

    static let unavailable = GroundingBrowserMetadata(
        source: .unavailable,
        isWebSurface: false,
        roleCategory: .unknown,
        elementClickable: nil,
        elementInteractable: nil,
        elementDisabled: nil,
        elementHidden: nil,
        elementCovered: nil
    )
}

struct GroundingOCRCandidate: Equatable {
    let text: String
    let confidence: Float
}

struct GroundingAuxiliarySignal: Equatable {
    let source: GroundingAuxiliarySignalSource
    let result: GroundingAuxiliarySignalResult
    let contradictionReasons: [GroundingSensorFusionContradiction]
    let latencyMs: Int?

    static func confirmed(_ source: GroundingAuxiliarySignalSource, latencyMs: Int? = nil) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(source: source, result: .confirmed, contradictionReasons: [], latencyMs: latencyMs)
    }

    static func weaklyConfirmed(_ source: GroundingAuxiliarySignalSource, latencyMs: Int? = nil) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(source: source, result: .weaklyConfirmed, contradictionReasons: [], latencyMs: latencyMs)
    }

    static func inconclusive(_ source: GroundingAuxiliarySignalSource, latencyMs: Int? = nil) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(source: source, result: .inconclusive, contradictionReasons: [], latencyMs: latencyMs)
    }

    static func unavailable(_ source: GroundingAuxiliarySignalSource, latencyMs: Int? = nil) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(source: source, result: .unavailable, contradictionReasons: [], latencyMs: latencyMs)
    }

    static func contradicted(
        _ source: GroundingAuxiliarySignalSource,
        _ reasons: [GroundingSensorFusionContradiction],
        latencyMs: Int? = nil
    ) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(source: source, result: .contradicted, contradictionReasons: reasons, latencyMs: latencyMs)
    }

    func withLatency(_ latencyMs: Int) -> GroundingAuxiliarySignal {
        GroundingAuxiliarySignal(
            source: source,
            result: result,
            contradictionReasons: contradictionReasons,
            latencyMs: latencyMs
        )
    }
}

struct GroundingSensorFusionLatency: Equatable {
    let sensorFusionLatencyMs: Int
    let cursorMetadataLatencyMs: Int?
    let ocrLatencyMs: Int?
    let axLatencyMs: Int?
    let browserMetadataLatencyMs: Int?
    let totalPointDecisionLatencyMs: Int
}

struct GroundingSensorFusionEvidence: Equatable {
    let primaryVisionTargetId: String?
    let targetElementIdHash: String?
    let targetFingerprint: TargetFingerprint?
    let regionQuality: RegionQuality
    let actionRisk: GroundingActionRisk
    let screenType: GroundingScreenType
    let stageType: GroundingStageType
    let journeyDecision: GroundingJourneyDecision
    let calibrationDecision: GroundingCalibrationDecision
    let fastPathDecision: GroundingFastPathDecision
    let dotSuppressedByLatency: Bool
    let preDotVerificationReasons: [GroundingPreDotVerificationReason]
    let policyContradictions: [GroundingSensorFusionContradiction]
    let signals: [GroundingAuxiliarySignal]
    let latency: GroundingSensorFusionLatency

    var requiresPreDotVerification: Bool {
        !preDotVerificationReasons.isEmpty
    }
}

struct GroundingSensorFusionDecision: Equatable {
    let evidence: GroundingSensorFusionEvidence
    let finalDecision: GroundingSensorFusionDecisionKind
    let shouldBlockPoint: Bool
    let userFacingReason: String

    var targetElementIdHash: String? {
        evidence.targetElementIdHash
    }

    var confirmedSources: [GroundingAuxiliarySignalSource] {
        evidence.signals.compactMap { signal in
            switch signal.result {
            case .confirmed, .weaklyConfirmed:
                return signal.source
            case .inconclusive, .contradicted, .unavailable:
                return nil
            }
        }
    }

    var contradictedSources: [GroundingAuxiliarySignalSource] {
        evidence.signals.compactMap { signal in
            signal.result == .contradicted ? signal.source : nil
        }
    }

    var contradictionReasons: [GroundingSensorFusionContradiction] {
        var seen = Set<String>()
        var reasons: [GroundingSensorFusionContradiction] = []
        for reason in evidence.signals.flatMap(\.contradictionReasons) + evidence.policyContradictions {
            guard !seen.contains(reason.rawValue) else { continue }
            seen.insert(reason.rawValue)
            reasons.append(reason)
        }
        return reasons
    }

    var requiresPreDotVerification: Bool {
        evidence.requiresPreDotVerification && !shouldBlockPoint
    }
}
