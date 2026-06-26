//
//  GuidedSetupSemanticOutcomeEvaluator.swift
//  leanring-buddy
//
//  Pure semantic evidence extraction for guided setup point-outcome checks.
//

import Foundation

struct GuidedSetupSemanticOutcomeEvidence {
    let targetReappeared: Bool
    let modalVisible: Bool
    let selectedTargetVisible: Bool
    let focusedFieldVisible: Bool
    let filledFieldVisible: Bool
    let enabledButtonVisible: Bool
    let disabledButtonVisible: Bool
    let dropdownVisible: Bool
    let warningVisible: Bool
    let warningCleared: Bool
    let modalClosed: Bool
    let wizardAdvanced: Bool
}

enum GuidedSetupSemanticOutcomeEvaluator {
    static func evaluate(
        in semanticGrounding: SpiderGuideSemanticGrounding?,
        stageId: String,
        expectedOutcome: SpiderGuideExpectedOutcome,
        targetElementIdHash: String?,
        targetFingerprint: TargetFingerprint?
    ) -> GuidedSetupSemanticOutcomeEvidence {
        guard let semanticGrounding else {
            return emptyEvidence
        }

        let targets = semanticGrounding.interactiveTargets + semanticGrounding.blockedTargets
        let modalVisible = containsModal(in: semanticGrounding, targets: targets)
        let dropdownVisible = containsDropdown(in: semanticGrounding, targets: targets)
        let warningVisible = containsWarning(in: semanticGrounding, targets: targets)
        let matchingTarget = firstMatchingTarget(
            in: semanticGrounding,
            targets: targets,
            stageId: stageId,
            expectedOutcome: expectedOutcome,
            targetElementIdHash: targetElementIdHash,
            targetFingerprint: targetFingerprint
        )
        let normalizedRole = matchingTarget?.role.lowercased() ?? ""
        let normalizedState = matchingTarget?.state.lowercased() ?? ""
        let targetLooksLikeButton = ["button", "cta", "link", "tab", "toggle"].contains(normalizedRole)
        let targetLooksLikeField = ["field", "input", "text_field", "textarea"].contains(normalizedRole)

        return GuidedSetupSemanticOutcomeEvidence(
            targetReappeared: matchingTarget != nil,
            modalVisible: modalVisible,
            selectedTargetVisible: normalizedState == "selected",
            focusedFieldVisible: targetLooksLikeField && normalizedState == "focused",
            filledFieldVisible: targetLooksLikeField && normalizedState == "filled",
            enabledButtonVisible: targetLooksLikeButton && normalizedState == "enabled",
            disabledButtonVisible: targetLooksLikeButton && normalizedState == "disabled",
            dropdownVisible: dropdownVisible,
            warningVisible: warningVisible,
            warningCleared: !warningVisible,
            modalClosed: !modalVisible,
            wizardAdvanced: false
        )
    }

    private static var emptyEvidence: GuidedSetupSemanticOutcomeEvidence {
        GuidedSetupSemanticOutcomeEvidence(
            targetReappeared: false,
            modalVisible: false,
            selectedTargetVisible: false,
            focusedFieldVisible: false,
            filledFieldVisible: false,
            enabledButtonVisible: false,
            disabledButtonVisible: false,
            dropdownVisible: false,
            warningVisible: false,
            warningCleared: false,
            modalClosed: false,
            wizardAdvanced: false
        )
    }

    private static func containsModal(
        in semanticGrounding: SpiderGuideSemanticGrounding,
        targets: [SpiderGuideSemanticTarget]
    ) -> Bool {
        targets.contains { target in
            ["modal", "dialog", "popover"].contains(target.container.lowercased())
        } || semanticGrounding.elements.contains { element in
            ["modal", "dialog", "popover"].contains(element.role.lowercased())
        }
    }

    private static func containsDropdown(
        in semanticGrounding: SpiderGuideSemanticGrounding,
        targets: [SpiderGuideSemanticTarget]
    ) -> Bool {
        targets.contains { target in
            let role = target.role.lowercased()
            let container = target.container.lowercased()
            let state = target.state.lowercased()
            return ["dropdown", "menu", "popover"].contains(container)
                || ["menu", "menu_item", "select", "dropdown"].contains(role)
                || ["expanded", "open"].contains(state)
        } || semanticGrounding.elements.contains { element in
            ["menu", "menuitem", "listbox", "combobox", "popupbutton"].contains(element.role.lowercased())
        }
    }

    private static func containsWarning(
        in semanticGrounding: SpiderGuideSemanticGrounding,
        targets: [SpiderGuideSemanticTarget]
    ) -> Bool {
        targets.contains { target in
            let role = target.role.lowercased()
            let container = target.container.lowercased()
            return target.risk.lowercased() != "low"
                || ["alert", "warning"].contains(role)
                || ["alert", "warning"].contains(container)
        } || semanticGrounding.elements.contains { element in
            ["alert", "warning"].contains(element.role.lowercased())
        }
    }

    private static func firstMatchingTarget(
        in semanticGrounding: SpiderGuideSemanticGrounding,
        targets: [SpiderGuideSemanticTarget],
        stageId: String,
        expectedOutcome: SpiderGuideExpectedOutcome,
        targetElementIdHash: String?,
        targetFingerprint: TargetFingerprint?
    ) -> SpiderGuideSemanticTarget? {
        targets.first { target in
            guard let targetElementIdHash,
                  let elementId = target.elementId else {
                return false
            }
            return SpiderGroundingPrivacy.targetElementIdHash(for: elementId) == targetElementIdHash
        } ?? targets.first { target in
            guard let targetFingerprint,
                  let candidateFingerprint = TargetFingerprint.make(
                      target: target,
                      grounding: semanticGrounding,
                      stageId: stageId,
                      expectedOutcome: expectedOutcome
                  ) else {
                return false
            }
            return targetFingerprint.isCompatible(with: candidateFingerprint)
        } ?? targets.first { target in
            guard targetElementIdHash == nil, targetFingerprint == nil else { return false }
            return ["selected", "focused", "filled", "disabled"].contains(target.state.lowercased())
        }
    }
}
