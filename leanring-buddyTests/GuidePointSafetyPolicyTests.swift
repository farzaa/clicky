//
//  GuidePointSafetyPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for final point safety gates before overlay use.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct GuidePointSafetyPolicyTests {
    @Test func rejectsUnsafeScreenStates() async throws {
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )

        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: response,
                resolvedScreenState: .loading
            ) == .unrecognizedScreen
        )
        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: response,
                resolvedScreenState: .unknown
            ) == .unrecognizedScreen
        )
        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: response,
                resolvedScreenState: .blocked
            ) == .unrecognizedScreen
        )
    }

    @Test func initialPointDecisionMakesPointEligibilityExplicit() async throws {
        let safePoint = guidePoint(expectedOutcome: .tileSelected)
        let safeResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: safePoint,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        let noPointResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: nil,
            targets: []
        )

        #expect(
            SpiderGuidePointSafetyPolicy.initialPointDecision(
                for: noPointResponse,
                resolvedScreenState: .recognized
            ) == .noPoint
        )
        #expect(
            SpiderGuidePointSafetyPolicy.initialPointDecision(
                for: safeResponse,
                resolvedScreenState: .loading
            ) == .rejected(.unrecognizedScreen)
        )
        #expect(
            SpiderGuidePointSafetyPolicy.initialPointDecision(
                for: safeResponse,
                resolvedScreenState: .recognized,
                hasNegativeMemoryBlock: true
            ) == .rejected(.negativeMemoryBlocked)
        )
        #expect(
            SpiderGuidePointSafetyPolicy.initialPointDecision(
                for: safeResponse,
                resolvedScreenState: .recognized
            ) == .evaluable(safePoint)
        )
    }

    @Test func keepsManualSpendBoundariesClosed() async throws {
        let unsafeLabelResponse = guideResponse(
            semanticSignature: "semantic:review",
            point: guidePoint(label: "Publish campaign", expectedOutcome: .buttonEnabled),
            targets: [
                semanticTarget(elementId: "publish_button", label: "Publish campaign", state: "enabled"),
            ]
        )
        let restrictedStageResponse = guideResponse(
            semanticSignature: "semantic:budget",
            point: guidePoint(label: "Daily budget", expectedOutcome: .fieldFocused),
            targets: [
                semanticTarget(elementId: "budget_field", label: "Daily budget", state: "enabled"),
            ],
            stageId: "budget_boundary"
        )
        let manualConfirmationResponse = guideResponse(
            semanticSignature: "semantic:review",
            point: guidePoint(label: "Review", expectedOutcome: .buttonEnabled),
            targets: [
                semanticTarget(elementId: "review_button", label: "Review", state: "enabled"),
            ],
            requiresManualConfirmation: true
        )

        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: unsafeLabelResponse,
                resolvedScreenState: .recognized
            ) == .unsafeLabel
        )
        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: restrictedStageResponse,
                resolvedScreenState: .recognized
            ) == .restrictedStage
        )
        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: manualConfirmationResponse,
                resolvedScreenState: .recognized
            ) == .manualConfirmationRequired
        )
    }

    @Test func rejectsSensitivePointEvidence() async throws {
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(
                label: "Continue",
                missionAlignment: "Matches jane@example.com",
                expectedOutcome: .buttonEnabled
            ),
            targets: [
                semanticTarget(elementId: "continue_button", label: "Continue", state: "enabled"),
            ]
        )

        #expect(
            SpiderGuidePointSafetyPolicy.rejectionReason(
                for: response,
                resolvedScreenState: .recognized
            ) == .sensitiveEvidence
        )
    }

    @Test func mapsSensorFusionBlocksToStableReasons() async throws {
        let actionRiskDecision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
            ],
            policyContradictions: [
                .actionRiskBlocked,
            ]
        )
        let staleTargetDecision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
            ],
            policyContradictions: [
                .targetStaleAfterScreenChange,
            ]
        )

        #expect(SpiderGuidePointSafetyPolicy.rejectionReason(for: actionRiskDecision) == .actionRiskBlocked)
        #expect(SpiderGuidePointSafetyPolicy.negativeMemoryReason(for: actionRiskDecision) == .actionRiskBlocked)
        #expect(SpiderGuidePointSafetyPolicy.shouldHideGuidanceBubble(for: .actionRiskBlocked))
        #expect(SpiderGuidePointSafetyPolicy.rejectionReason(for: staleTargetDecision) == .targetStaleAfterScreenChange)
        #expect(SpiderGuidePointSafetyPolicy.negativeMemoryReason(for: staleTargetDecision) == .stale)
    }
}
