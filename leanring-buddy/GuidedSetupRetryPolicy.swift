//
//  GuidedSetupRetryPolicy.swift
//  leanring-buddy
//
//  Retry rules for guided setup point-outcome verification.
//

import Foundation

enum GuidedSetupRetryPolicy {
    static func resolve(
        for status: GuidedPointOutcomeStatus,
        actualOutcomeEvidence: ActualOutcomeEvidence,
        attemptCount: Int
    ) -> GroundingRetryPolicy {
        switch status {
        case .confirmed:
            return GroundingRetryPolicy(
                allowRetry: true,
                maxAttemptsForSameTarget: 1,
                requiresNewSemanticSignature: false,
                requiresTargetReappearance: false,
                requiresUserConfirmation: false,
                reason: .outcomeConfirmed,
                doNotRepeatUntilSignatureChanges: false,
                requiresUserConfirmationAfterFailure: false
            )
        case .unclear:
            return GroundingRetryPolicy(
                allowRetry: true,
                maxAttemptsForSameTarget: max(1, attemptCount),
                requiresNewSemanticSignature: false,
                requiresTargetReappearance: true,
                requiresUserConfirmation: false,
                reason: .screenChangedWithoutConfirmation,
                doNotRepeatUntilSignatureChanges: false,
                requiresUserConfirmationAfterFailure: false
            )
        case .failed:
            return GroundingRetryPolicy(
                allowRetry: false,
                maxAttemptsForSameTarget: max(1, attemptCount),
                requiresNewSemanticSignature: true,
                requiresTargetReappearance: true,
                requiresUserConfirmation: true,
                reason: .noVisualChangeAfterAction,
                doNotRepeatUntilSignatureChanges: true,
                requiresUserConfirmationAfterFailure: true
            )
        case .stale:
            return GroundingRetryPolicy(
                allowRetry: false,
                maxAttemptsForSameTarget: max(1, attemptCount),
                requiresNewSemanticSignature: true,
                requiresTargetReappearance: true,
                requiresUserConfirmation: true,
                reason: actualOutcomeEvidence.blockedOrUnknownAfterAction
                    ? .blockedOrUnknownAfterAction
                    : .noVisualChangeAfterAction,
                doNotRepeatUntilSignatureChanges: true,
                requiresUserConfirmationAfterFailure: true
            )
        }
    }
}
