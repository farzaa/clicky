//
//  GroundingContextClassifier.swift
//  leanring-buddy
//
//  Classifies the current guided-setup context before local sensor fusion
//  decides whether a Vision-selected guide point can carry the Spider dot.
//

import Foundation

struct GroundingContextClassification: Equatable {
    let actionRisk: GroundingActionRisk
    let screenType: GroundingScreenType
    let stageType: GroundingStageType
    let journeyDecision: GroundingJourneyDecision
}

enum GroundingContextClassifier {
    private static let billingRiskFragments = [
        "billing", "payment", "card", "bank", "tax", "invoice", "pay", "checkout",
    ]
    private static let authenticationRiskFragments = [
        "2fa", "two-factor", "two factor", "verification code", "security code",
        "password", "credential", "login", "auth", "recovery",
    ]
    private static let publishRiskFragments = [
        "publish", "launch", "submit", "go live", "send campaign", "place order",
    ]
    private static let spendRiskFragments = [
        "budget", "spend", "bid", "spending limit", "increase budget", "daily budget",
    ]
    private static let policyRiskFragments = [
        "policy", "appeal", "account quality", "business verification", "domain verification",
    ]
    private static let destructiveRiskFragments = [
        "delete", "remove", "discard", "deactivate", "pause", "irreversible", "destructive",
    ]

    static func classify(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        target: SpiderGuideSemanticTarget?
    ) -> GroundingContextClassification {
        let actionRisk = actionRisk(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            target: target
        )
        let screenType = screenType(
            guideResponse: guideResponse,
            guidePoint: guidePoint,
            target: target
        )
        let stageType = stageType(
            guideResponse: guideResponse,
            screenType: screenType,
            actionRisk: actionRisk
        )
        let journeyDecision = journeyDecision(
            guidePoint: guidePoint,
            screenType: screenType,
            actionRisk: actionRisk
        )

        return GroundingContextClassification(
            actionRisk: actionRisk,
            screenType: screenType,
            stageType: stageType,
            journeyDecision: journeyDecision
        )
    }

    private static func actionRisk(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        target: SpiderGuideSemanticTarget?
    ) -> GroundingActionRisk {
        let normalizedContext = [
            guideResponse.screenId,
            guideResponse.stageId,
            guidePoint.expectedOutcome.rawValue,
            target?.role,
            target?.container,
            target?.state,
            target?.risk,
            target?.semanticIntent,
            target?.label,
            target?.affordance,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if containsAny(normalizedContext, billingRiskFragments) {
            return .billingBoundary
        }
        if containsAny(normalizedContext, authenticationRiskFragments) {
            return .authBoundary
        }
        if containsAny(normalizedContext, publishRiskFragments) {
            return .publishBoundary
        }
        if containsAny(normalizedContext, spendRiskFragments) {
            return .spendBoundary
        }
        if containsAny(normalizedContext, policyRiskFragments) {
            return .policyBoundary
        }
        if containsAny(normalizedContext, destructiveRiskFragments) {
            return .destructive
        }
        if let rawRisk = target?.risk.lowercased(),
           rawRisk == "restricted" || rawRisk == "high" || rawRisk == "medium" {
            return .unknown
        }

        switch GroundingExpectedOutcomeKind(expectedOutcome: guidePoint.expectedOutcome) {
        case .tileSelected:
            return .selection
        case .dropdownOpened, .modalOpened, .modalClosed, .buttonEnabled, .buttonDisabled,
             .stateChanged, .warningAppeared, .warningCleared:
            return .reversible
        case .fieldFocused, .fieldFilled:
            return .input
        case .screenAdvanced, .wizardAdvanced:
            return .navigation
        case .unknown:
            break
        }

        switch target?.affordance.lowercased() {
        case "select":
            return .selection
        case "type":
            return .input
        case "click":
            return .reversible
        case "read":
            return .readOnly
        case "wait":
            return .wait
        case "confirm_manually":
            return .unknown
        default:
            return .unknown
        }
    }

    private static func screenType(
        guideResponse: SpiderGuideResponse,
        guidePoint: SpiderGuidePoint,
        target: SpiderGuideSemanticTarget?
    ) -> GroundingScreenType {
        if guideResponse.screenState == .loading {
            return .loadingSkeleton
        }

        let semanticGrounding = guideResponse.semanticGrounding
        let targets = (semanticGrounding?.interactiveTargets ?? []) + (semanticGrounding?.blockedTargets ?? [])
        let elements = semanticGrounding?.elements ?? []
        let normalizedContext = [
            guideResponse.screenId,
            guideResponse.stageId,
            target?.container,
            target?.role,
            target?.semanticIntent,
            target?.state,
            guidePoint.expectedOutcome.rawValue,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if containsAny(normalizedContext, ["publish", "billing", "payment", "budget_boundary", "review_publish"]) {
            return .reviewPublishBoundary
        }
        if targets.contains(where: { ["modal", "dialog", "popover"].contains($0.container.lowercased()) })
            || elements.contains(where: { ["modal", "dialog", "popover"].contains($0.role.lowercased()) }) {
            return .modalDialogPopover
        }
        if targets.contains(where: { target in
            let role = target.role.lowercased()
            let container = target.container.lowercased()
            let state = target.state.lowercased()
            return ["menu", "dropdown", "select"].contains(role)
                || ["popover"].contains(container)
                || ["open", "expanded"].contains(state)
        }) {
            return .dropdown
        }
        if targets.contains(where: { target in
            ["alert", "warning"].contains(target.role.lowercased())
                || ["alert", "warning"].contains(target.container.lowercased())
                || target.state.lowercased() == "warning"
        }) {
            return .alertWarning
        }
        if targets.contains(where: { target in
            target.role.lowercased() == "table" || target.container.lowercased() == "table"
        }) {
            return .table
        }
        if GroundingExpectedOutcomeKind(expectedOutcome: guidePoint.expectedOutcome) == .tileSelected {
            return .cardTileSelection
        }
        if targets.contains(where: {
            $0.role.lowercased() == "field" || ["empty", "focused", "filled"].contains($0.state.lowercased())
        }) {
            return .form
        }
        if containsAny(normalizedContext, ["wizard", "objective", "campaign", "adset", "creative", "tracking", "setup"]) {
            return .wizard
        }
        return .unknown
    }

    private static func stageType(
        guideResponse: SpiderGuideResponse,
        screenType: GroundingScreenType,
        actionRisk: GroundingActionRisk
    ) -> GroundingStageType {
        if screenType == .loadingSkeleton || guideResponse.screenState == .loading {
            return .loading
        }
        if actionRisk.isSensitiveBoundary || screenType == .reviewPublishBoundary || guideResponse.requiresManualConfirmation {
            return .sensitiveBoundary
        }
        if guideResponse.screenState == .recognized || guideResponse.screenState == nil {
            return .safeSetup
        }
        return .unknown
    }

    private static func journeyDecision(
        guidePoint: SpiderGuidePoint,
        screenType: GroundingScreenType,
        actionRisk: GroundingActionRisk
    ) -> GroundingJourneyDecision {
        guard actionRisk.allowsDot else {
            let transition: GroundingJourneyTransitionKind = actionRisk.isSensitiveBoundary
                ? .reviewToManualBoundary
                : .invalidBoundary
            return GroundingJourneyDecision(transition: transition, allowsDot: false)
        }
        guard screenType != .reviewPublishBoundary else {
            return GroundingJourneyDecision(transition: .reviewToManualBoundary, allowsDot: false)
        }

        let outcomeKind = GroundingExpectedOutcomeKind(expectedOutcome: guidePoint.expectedOutcome)
        switch (screenType, outcomeKind) {
        case (.wizard, .screenAdvanced), (.wizard, .wizardAdvanced):
            return GroundingJourneyDecision(transition: .wizardToForm, allowsDot: true)
        case (.wizard, .modalOpened), (.table, .modalOpened):
            return GroundingJourneyDecision(transition: .tableToModal, allowsDot: true)
        case (.modalDialogPopover, .modalClosed):
            return GroundingJourneyDecision(transition: .modalToClosed, allowsDot: true)
        case (.modalDialogPopover, .fieldFocused), (.modalDialogPopover, .fieldFilled):
            return GroundingJourneyDecision(transition: .modalToForm, allowsDot: true)
        case (.form, .dropdownOpened), (.wizard, .dropdownOpened):
            return GroundingJourneyDecision(transition: .formToDropdown, allowsDot: true)
        case (.dropdown, .tileSelected), (.cardTileSelection, .tileSelected):
            return GroundingJourneyDecision(transition: .dropdownToSelection, allowsDot: true)
        case (.form, .warningAppeared):
            return GroundingJourneyDecision(transition: .formToWarning, allowsDot: true)
        case (.alertWarning, .warningCleared):
            return GroundingJourneyDecision(transition: .warningToForm, allowsDot: true)
        case (.loadingSkeleton, _):
            return GroundingJourneyDecision(transition: .loadingToRecognized, allowsDot: false)
        default:
            return GroundingJourneyDecision(transition: .sameScreen, allowsDot: true)
        }
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
