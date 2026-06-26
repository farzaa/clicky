//
//  GuidedSetupOutcomeContracts.swift
//  leanring-buddy
//
//  Typed contracts for guided setup outcome verification, pre-dot checks, and
//  negative target memory. These types are shared by session state, telemetry,
//  and local sensor fusion without storing screen content.
//

import Foundation

enum GuidedPointOutcomeStatus: String {
    case confirmed = "outcome_confirmed"
    case unclear = "outcome_unclear"
    case failed = "outcome_failed"
    case stale = "outcome_stale"
}

enum GroundingRetryReason: String {
    case outcomeConfirmed = "outcome_confirmed"
    case screenChangedWithoutConfirmation = "screen_changed_without_confirmation"
    case noVisualChangeAfterAction = "no_visual_change_after_action"
    case blockedOrUnknownAfterAction = "blocked_or_unknown_after_action"
    case failedOutcome = "failed_outcome"
    case stale = "stale"
    case regionBad = "region_bad"
    case sensorContradiction = "sensor_contradiction"
    case actionRiskBlocked = "action_risk_blocked"
    case preDotVerificationFailed = "pre_dot_verification_failed"
    case preDotVerificationTimeout = "pre_dot_verification_timeout"
    case journeyTransitionInvalid = "journey_transition_invalid"
}

enum GroundingExpectedOutcomeKind: String, Equatable {
    case tileSelected
    case modalOpened
    case modalClosed
    case dropdownOpened
    case fieldFocused
    case fieldFilled
    case buttonEnabled
    case buttonDisabled
    case screenAdvanced
    case wizardAdvanced
    case stateChanged
    case warningAppeared
    case warningCleared
    case unknown

    init(expectedOutcome: SpiderGuideExpectedOutcome) {
        switch expectedOutcome {
        case .stageAdvanced, .screenAdvanced:
            self = .screenAdvanced
        case .wizardAdvanced:
            self = .wizardAdvanced
        case .modalOpened:
            self = .modalOpened
        case .modalClosed:
            self = .modalClosed
        case .dropdownOpened:
            self = .dropdownOpened
        case .itemSelected, .tileSelected:
            self = .tileSelected
        case .fieldFocused:
            self = .fieldFocused
        case .fieldFilled:
            self = .fieldFilled
        case .buttonEnabled:
            self = .buttonEnabled
        case .buttonDisabled:
            self = .buttonDisabled
        case .warningAppeared:
            self = .warningAppeared
        case .warningCleared:
            self = .warningCleared
        case .stateChanged:
            self = .stateChanged
        case .unknown:
            self = .unknown
        }
    }
}

struct ExpectedOutcomeEvidence: Equatable {
    let expectedOutcome: SpiderGuideExpectedOutcome
    let verificationKind: GroundingExpectedOutcomeKind
    let targetElementIdHash: String?
    let targetFingerprint: TargetFingerprint?
    let startingScreenId: String
    let startingStageId: String
    let startingSemanticSignature: String?
    let startingGroundingRevision: GroundingRevision?
    let expectedStageChange: Bool
    let expectedSemanticSignatureChange: Bool
    let expectedTargetStateChange: Bool
    let expectedModalChange: Bool
    let expectedScreenStateAfterAction: SpiderGuideScreenState?

    init(
        acceptedPoint: SpiderGuidePoint,
        targetElementIdHash: String?,
        targetFingerprint: TargetFingerprint?,
        startingScreenId: String,
        startingStageId: String,
        startingSemanticSignature: String?,
        startingGroundingRevision: GroundingRevision?
    ) {
        self.expectedOutcome = acceptedPoint.expectedOutcome
        self.verificationKind = GroundingExpectedOutcomeKind(expectedOutcome: acceptedPoint.expectedOutcome)
        self.targetElementIdHash = targetElementIdHash
        self.targetFingerprint = targetFingerprint
        self.startingScreenId = startingScreenId
        self.startingStageId = startingStageId
        self.startingSemanticSignature = startingSemanticSignature
        self.startingGroundingRevision = startingGroundingRevision
        self.expectedStageChange = self.verificationKind == .screenAdvanced || self.verificationKind == .wizardAdvanced
        self.expectedSemanticSignatureChange = [
            .dropdownOpened,
            .modalOpened,
            .modalClosed,
            .itemSelected,
            .tileSelected,
            .fieldFocused,
            .fieldFilled,
            .buttonEnabled,
            .buttonDisabled,
            .wizardAdvanced,
            .warningAppeared,
            .warningCleared,
            .stateChanged,
        ].contains(acceptedPoint.expectedOutcome)
        self.expectedTargetStateChange = [
            .dropdownOpened,
            .itemSelected,
            .tileSelected,
            .fieldFocused,
            .fieldFilled,
            .buttonEnabled,
            .buttonDisabled,
            .warningAppeared,
            .warningCleared,
            .stateChanged,
        ].contains(acceptedPoint.expectedOutcome)
        self.expectedModalChange = self.verificationKind == .modalOpened || self.verificationKind == .modalClosed
        self.expectedScreenStateAfterAction = .recognized
    }
}

struct ActualOutcomeEvidence: Equatable {
    let nextScreenState: SpiderGuideScreenState
    let nextScreenConfidence: SpiderGuideConfidence
    let nextScreenId: String
    let nextStageId: String
    let nextSemanticSignature: String?
    let screenChanged: Bool
    let stageChanged: Bool
    let semanticSignatureChanged: Bool
    let targetReappeared: Bool
    let targetStillSame: Bool
    let modalVisible: Bool
    let selectedTargetVisible: Bool
    let focusedFieldVisible: Bool
    let filledFieldVisible: Bool
    let enabledButtonVisible: Bool
    let disabledButtonVisible: Bool
    let dropdownVisible: Bool
    let modalClosed: Bool
    let wizardAdvanced: Bool
    let warningVisible: Bool
    let warningCleared: Bool
    let blockedOrUnknownAfterAction: Bool
    let outcomeStatus: GuidedPointOutcomeStatus
}

struct GroundingRetryPolicy: Equatable {
    let allowRetry: Bool
    let maxAttemptsForSameTarget: Int
    let requiresNewSemanticSignature: Bool
    let requiresTargetReappearance: Bool
    let requiresUserConfirmation: Bool
    let reason: GroundingRetryReason
    let doNotRepeatUntilSignatureChanges: Bool
    let requiresUserConfirmationAfterFailure: Bool
}

struct GroundingOutcomeDecision: Equatable {
    let expectedOutcomeEvidence: ExpectedOutcomeEvidence
    let actualOutcomeEvidence: ActualOutcomeEvidence
    let retryPolicy: GroundingRetryPolicy

    var outcomeStatus: GuidedPointOutcomeStatus {
        actualOutcomeEvidence.outcomeStatus
    }
}

struct PendingGuidePointOutcome: Equatable {
    let expectedOutcomeEvidence: ExpectedOutcomeEvidence
    let attemptCount: Int

    var targetElementIdHash: String? {
        expectedOutcomeEvidence.targetElementIdHash
    }

    var targetFingerprint: TargetFingerprint? {
        expectedOutcomeEvidence.targetFingerprint
    }

    var screenId: String {
        expectedOutcomeEvidence.startingScreenId
    }

    var stageId: String {
        expectedOutcomeEvidence.startingStageId
    }

    var semanticSignature: String? {
        expectedOutcomeEvidence.startingSemanticSignature
    }

    var groundingRevision: GroundingRevision? {
        expectedOutcomeEvidence.startingGroundingRevision
    }

    var expectedOutcome: SpiderGuideExpectedOutcome {
        expectedOutcomeEvidence.expectedOutcome
    }
}

enum GroundingNegativeMemoryReason: String, Equatable {
    case failedOutcome = "failed_outcome"
    case stale
    case regionBad = "region_bad"
    case sensorContradiction = "sensor_contradiction"
    case actionRiskBlocked = "action_risk_blocked"
    case preDotVerificationFailed = "pre_dot_verification_failed"
    case preDotVerificationTimeout = "pre_dot_verification_timeout"
    case journeyTransitionInvalid = "journey_transition_invalid"
}

struct GroundingNegativeMemoryEntry: Equatable {
    let targetElementIdHash: String?
    let targetFingerprint: TargetFingerprint?
    let semanticSignature: String?
    let screenSignature: String?
    let stageId: String
    let reason: GroundingNegativeMemoryReason
    let createdAt: Date
    let expiresAt: Date
    let pollIndex: Int?
}

enum PreDotVerificationStatus: Equatable {
    case notRequired
    case pending
    case confirmed
    case failed
}

struct PreDotVerificationDecision: Equatable {
    let status: PreDotVerificationStatus
    let reason: SpiderGuidePointRejectionReason?
    let latencyMs: Int?

    init(
        status: PreDotVerificationStatus,
        reason: SpiderGuidePointRejectionReason?,
        latencyMs: Int? = nil
    ) {
        self.status = status
        self.reason = reason
        self.latencyMs = latencyMs
    }
}

struct PendingPreDotVerification: Equatable {
    let targetElementIdHash: String?
    let targetFingerprint: TargetFingerprint?
    let regionQuality: RegionQuality
    let actionRisk: GroundingActionRisk
    let screenType: GroundingScreenType
    let stageType: GroundingStageType
    let expectedOutcome: SpiderGuideExpectedOutcome
    let semanticSignature: String?
    let screenSignature: String
    let requestedAt: Date
    let pollIndex: Int?
    let reasons: [GroundingPreDotVerificationReason]
}
