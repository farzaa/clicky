//
//  SpiderGuidePointRejectionReason.swift
//  leanring-buddy
//
//  Privacy-safe reasons for rejecting a Vision-selected guide point before it
//  reaches the cursor overlay.
//

import Foundation

enum SpiderGuidePointRejectionReason: String {
    case unrecognizedScreen = "unrecognized_screen"
    case lowConfidence = "low_confidence"
    case manualConfirmationRequired = "manual_confirmation_required"
    case restrictedScreen = "restricted_screen"
    case restrictedStage = "restricted_stage"
    case unsafeLabel = "unsafe_label"
    case missingMissionAlignment = "missing_mission_alignment"
    case sensitiveEvidence = "sensitive_evidence"
    case pointOutsideRegion = "point_outside_region"
    case targetConfidenceLow = "target_confidence_low"
    case targetStaleAfterScreenChange = "target_stale_after_screen_change"
    case blockedTargetOverlap = "blocked_target_overlap"
    case modalContextMismatch = "modal_context_mismatch"
    case affordanceNotClickable = "affordance_not_clickable"
    case regionImplausible = "region_implausible"
    case semanticSignatureChanged = "semantic_signature_changed"
    case targetOccluded = "target_occluded"
    case elementMissing = "element_missing"
    case elementConfidenceLow = "element_confidence_low"
    case outcomeFailed = "outcome_failed"
    case outcomeStale = "outcome_stale"
    case sensitiveGroundingText = "sensitive_grounding_text"
    case sensorFusionContradicted = "sensor_fusion_contradicted"
    case actionRiskBlocked = "action_risk_blocked"
    case preDotVerificationPending = "pre_dot_verification_pending"
    case preDotVerificationFailed = "pre_dot_verification_failed"
    case preDotVerificationTimeout = "pre_dot_verification_timeout"
    case journeyTransitionInvalid = "journey_transition_invalid"
    case negativeMemoryBlocked = "negative_memory_blocked"
}
