//
//  GuidedSetupOutcomeStatusResolver.swift
//  leanring-buddy
//
//  Policy for classifying whether a previously pointed guided-setup target
//  produced the expected visual outcome.
//

import Foundation

enum GuidedSetupOutcomeStatusResolver {
    static func resolve(
        expectedOutcomeEvidence: ExpectedOutcomeEvidence,
        resolvedScreenState: SpiderGuideScreenState,
        screenChanged: Bool,
        screenAdvanced: Bool,
        semanticSignatureChanged: Bool,
        semanticOutcomeEvidence: GuidedSetupSemanticOutcomeEvidence
    ) -> GuidedPointOutcomeStatus {
        if screenChanged && resolvedScreenState == .blocked {
            return .stale
        }

        switch expectedOutcomeEvidence.verificationKind {
        case .screenAdvanced:
            return status(confirmed: screenAdvanced, screenChanged: screenChanged)
        case .wizardAdvanced:
            return status(
                confirmed: screenAdvanced || semanticOutcomeEvidence.wizardAdvanced,
                screenChanged: screenChanged
            )
        case .modalOpened:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.modalVisible,
                screenChanged: screenChanged
            )
        case .modalClosed:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.modalClosed,
                screenChanged: screenChanged
            )
        case .dropdownOpened:
            return status(confirmed: semanticOutcomeEvidence.dropdownVisible, screenChanged: screenChanged)
        case .tileSelected:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.selectedTargetVisible,
                screenChanged: screenChanged
            )
        case .fieldFocused:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.focusedFieldVisible,
                screenChanged: screenChanged
            )
        case .fieldFilled:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.filledFieldVisible,
                screenChanged: screenChanged
            )
        case .buttonEnabled:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.enabledButtonVisible,
                screenChanged: screenChanged
            )
        case .buttonDisabled:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged || semanticOutcomeEvidence.disabledButtonVisible,
                screenChanged: screenChanged
            )
        case .warningAppeared:
            return status(
                confirmed: semanticOutcomeEvidence.warningVisible || semanticSignatureChanged,
                screenChanged: screenChanged
            )
        case .warningCleared:
            return status(
                confirmed: semanticOutcomeEvidence.warningCleared || semanticSignatureChanged,
                screenChanged: screenChanged
            )
        case .stateChanged, .unknown:
            return status(
                confirmed: screenAdvanced || semanticSignatureChanged,
                screenChanged: screenChanged
            )
        }
    }

    private static func status(confirmed: Bool, screenChanged: Bool) -> GuidedPointOutcomeStatus {
        if confirmed {
            return .confirmed
        }
        return screenChanged ? .unclear : .failed
    }
}
