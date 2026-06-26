//
//  SpiderTestFixtures.swift
//  leanring-buddyTests
//
//  Shared domain fixtures for Spider Swift tests.
//

import CoreGraphics
import Foundation
@testable import Spider

func guidePoint(
    targetElementId: String? = "target",
    label: String = "Sales",
    missionAlignment: String? = "Matches mission",
    expectedOutcome: SpiderGuideExpectedOutcome
) -> SpiderGuidePoint {
    SpiderGuidePoint(
        x: 16,
        y: 16,
        label: label,
        screenNumber: nil,
        missionAlignment: missionAlignment,
        targetElementId: targetElementId,
        expectedOutcome: expectedOutcome
    )
}

func guideResponse(
    semanticSignature: String,
    point: SpiderGuidePoint?,
    targets: [SpiderGuideSemanticTarget],
    spokenText: String = "Choose this.",
    displayText: String = "Choose Sales",
    nextStep: String = "Choose Sales.",
    screenState: SpiderGuideScreenState? = .recognized,
    screenId: String = "objective_selection",
    stageId: String = "objective",
    screenConfidence: SpiderGuideConfidence? = .high,
    contextKind: SpiderGuideContextKind = .guidedSetup,
    requiresManualConfirmation: Bool = false,
    decisionMemoryUpdate: String? = nil,
    adMissionUpdate: AdMissionUpdate? = nil,
    artifact: SpiderArtifact? = nil
) -> SpiderGuideResponse {
    SpiderGuideResponse(
        spokenText: spokenText,
        displayText: displayText,
        nextStep: nextStep,
        semanticGrounding: semanticGrounding(semanticSignature: semanticSignature, targets: targets),
        screenState: screenState,
        screenId: screenId,
        stageId: stageId,
        screenConfidence: screenConfidence,
        screenEvidence: [],
        shouldContinuePolling: true,
        pollAfterMs: nil,
        contextKind: contextKind,
        officialRule: nil,
        spiderJudgment: "Safe setup step.",
        decision: .safeToContinue,
        riskLevel: .low,
        confidence: .high,
        sourceType: .spiderPlaybook,
        requiresManualConfirmation: requiresManualConfirmation,
        reviewTrigger: nil,
        decisionMemoryUpdate: decisionMemoryUpdate,
        point: point,
        adMissionUpdate: adMissionUpdate,
        artifact: artifact
    )
}

func semanticTarget(
    elementId: String,
    label: String,
    role: String = "button",
    container: String = "main_content",
    state: String,
    targetStability: String = "stable",
    region: SpiderGuideRegion = SpiderGuideRegion(x: 0, y: 0, width: 64, height: 44)
) -> SpiderGuideSemanticTarget {
    SpiderGuideSemanticTarget(
        elementId: elementId,
        label: label,
        role: role,
        container: container,
        parentLabel: nil,
        nearestText: [],
        semanticIntent: label,
        state: state,
        risk: "low",
        targetConfidence: .high,
        evidence: [],
        affordance: "click",
        targetStability: targetStability,
        region: region
    )
}

func semanticGrounding(
    semanticSignature: String,
    targets: [SpiderGuideSemanticTarget],
    blockedTargets: [SpiderGuideSemanticTarget] = []
) -> SpiderGuideSemanticGrounding {
    SpiderGuideSemanticGrounding(
        groundingRevision: "rev",
        semanticSignature: semanticSignature,
        elements: (targets + blockedTargets).map {
            SpiderGuideSceneGraphElement(
                id: $0.elementId ?? "target",
                label: $0.label,
                role: $0.role,
                containerId: nil,
                parentId: nil,
                zIndexHint: "front",
                occluded: false,
                region: $0.region,
                confidence: .high,
                evidence: []
            )
        },
        visibleConcepts: [],
        interactiveTargets: targets,
        blockedTargets: blockedTargets,
        uncertainty: []
    )
}

func syntheticScreenCapture(
    displayFrame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 120)
) -> CompanionScreenCapture {
    CompanionScreenCapture(
        imageData: Data(),
        label: "screen-1",
        isCursorScreen: true,
        displayWidthInPoints: 200,
        displayHeightInPoints: 120,
        displayFrame: displayFrame,
        screenshotWidthInPixels: 200,
        screenshotHeightInPixels: 120
    )
}

func fusionPolicy(
    fastPathMaxDecisionMs: Int = 260,
    ocrDeadlineMs: Int = 240,
    axDeadlineMs: Int = 140,
    browserDeadlineMs: Int = 140,
    preDotVerificationMaxMs: Int = 1_200,
    totalDecisionMaxMs: Int = 700
) -> GroundingSensorFusionPolicy {
    GroundingSensorFusionPolicy(
        pointRegionTolerancePixels: 6,
        blockedTargetOverlapTolerancePixels: 6,
        ocrRegionPaddingPixels: 16,
        ocrMinimumConfidence: 0.45,
        minimumOCRTokenCharacters: 3,
        ocrStrongMismatchMinimumCandidates: 2,
        ocrStrongMismatchMinimumTokenCount: 2,
        ocrStrongMismatchMinimumAverageConfidence: 0.72,
        maximumAXParentDepth: 4,
        localOCRLatencyCutoffMs: ocrDeadlineMs,
        accessibilityLatencyCutoffMs: axDeadlineMs,
        browserMetadataLatencyCutoffMs: browserDeadlineMs,
        totalPointDecisionLatencyCutoffMs: totalDecisionMaxMs,
        fastPathMaxDecisionMs: fastPathMaxDecisionMs,
        ocrDeadlineMs: ocrDeadlineMs,
        axDeadlineMs: axDeadlineMs,
        browserDeadlineMs: browserDeadlineMs,
        preDotVerificationMaxMs: preDotVerificationMaxMs,
        totalDecisionMaxMs: totalDecisionMaxMs,
        blockOnStrongContradiction: true
    )
}
