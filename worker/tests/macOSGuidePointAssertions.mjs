import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSGuidePointAssertions({ test, workerRoot }) {
  test("macOS app gates guide points before overlay use", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManager.swift"),
      "utf8"
    );
    const presentationActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerPresentationActions.swift"),
      "utf8"
    );
    const guidedSetupActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerGuidedSetupActions.swift"),
      "utf8"
    );
    const visionGuideActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerVisionGuideActions.swift"),
      "utf8"
    );
    const debugActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerDebugActions.swift"),
      "utf8"
    );
    const analyticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderAnalytics.swift"),
      "utf8"
    );
    const guidePointRejectionSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuidePointRejectionReason.swift"),
      "utf8"
    );
    const diagnosticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderDiagnostics.swift"),
      "utf8"
    );
    const groundingTelemetryRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryRecorder.swift"),
      "utf8"
    );
    const guidePointSafetyPolicySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuidePointSafetyPolicy.swift"),
      "utf8"
    );
    const guidePointEvaluatorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePointEvaluator.swift"),
      "utf8"
    );
    const guidePointSensorFusionRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePointSensorFusionRunner.swift"),
      "utf8"
    );
    const preDotVerificationCoordinatorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPreDotVerificationCoordinator.swift"),
      "utf8"
    );
    const visionGuideRequestRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionVisionGuideRequestRunner.swift"),
      "utf8"
    );
    const guidePointTelemetrySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePointTelemetryRecorder.swift"),
      "utf8"
    );
    const guidePointOverlayPlacementSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidePointOverlayPlacement.swift"),
      "utf8"
    );
    const guidePointOverlayPresenterSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePointOverlayPresenter.swift"),
      "utf8"
    );
    const guidedSetupSessionSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupSession.swift"),
      "utf8"
    );
    const outcomeContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupOutcomeContracts.swift"),
      "utf8"
    );
    const panelSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelView.swift"),
      "utf8"
    );
    const overlaySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OverlayWindow.swift"),
      "utf8"
    );
    const overlayWindowShellSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OverlayWindowShell.swift"),
      "utf8"
    );
    const overlayWindowManagerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OverlayWindowManager.swift"),
      "utf8"
    );
    const cursorNavigationModeSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderCursorNavigationMode.swift"),
      "utf8"
    );
    const cursorBubbleSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderCursorBubbleView.swift"),
      "utf8"
    );
    const guideTargetSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuideClickTargetView.swift"),
      "utf8"
    );
    const previewRenderScript = readFileSync(
      path.join(workerRoot, "..", "scripts", "render_mission_pointer_preview.sh"),
      "utf8"
    );
    const applyGuidePointSource = presentationActionsSource.match(
      /func applyGuidePoint\([\s\S]*?\n    }\n\n    func ensureProductFeatureAvailable/
    )?.[0] ?? "";

    assert.match(guidePointSafetyPolicySource, /enum SpiderGuidePointSafetyPolicy/);
    assert.match(guidePointSafetyPolicySource, /restrictedScreenIds/);
    assert.match(guidePointSafetyPolicySource, /restrictedStageIds/);
    assert.match(guidePointSafetyPolicySource, /unsafePointLabelFragments/);
    assert.match(guidePointSafetyPolicySource, /sensitivePointEvidencePattern/);
    assert.match(guidePointSafetyPolicySource, /static func rejectionReason/);
    assert.match(guidePointSafetyPolicySource, /static func negativeMemoryReason/);
    assert.match(guidePointSafetyPolicySource, /static func shouldHideGuidanceBubble/);
    assert.match(guidePointEvaluatorSource, /enum CompanionGuidePointEvaluator/);
    assert.match(guidePointEvaluatorSource, /SpiderGuidePointSafetyPolicy\.initialPointDecision/);
    assert.match(guidePointEvaluatorSource, /SpiderGuidePointSafetyPolicy\.rejectionReason/);
    assert.match(guidePointEvaluatorSource, /CompanionGuidePointSensorFusionRunner\.evaluate/);
    assert.doesNotMatch(guidePointEvaluatorSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(guidePointSensorFusionRunnerSource, /GroundingSensorFusion\.evaluate/);
    assert.match(guidePointSensorFusionRunnerSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointEvaluator\.evaluate/);
    assert.match(preDotVerificationCoordinatorSource, /SpiderGuidePointSafetyPolicy\.negativeMemoryReason/);
    assert.match(visionGuideActionsSource, /CompanionPreDotVerificationCoordinator\.resolve/);
    assert.doesNotMatch(managerSource, /SpiderGuidePointSafetyPolicy\.negativeMemoryReason/);
    assert.match(visionGuideActionsSource, /SpiderGuidePointSafetyPolicy\.shouldHideGuidanceBubble/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointTelemetryRecorder\.recordRejected/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointEvaluator\.evaluate/);
    assert.doesNotMatch(managerSource, /CompanionPreDotVerificationCoordinator\.resolve/);
    assert.doesNotMatch(managerSource, /private func recordGuidePointRejection/);
    assert.doesNotMatch(managerSource, /GroundingTelemetryRecorder\.recordGuidePointRejection/);
    assert.match(guidePointTelemetrySource, /GroundingTelemetryRecorder\.recordGuidePointRejection/);
    assert.match(managerSource, /detectedElementPointLabel/);
    assert.match(managerSource, /detectedElementMissionAlignment/);
    assert.match(presentationActionsSource, /extension CompanionManager/);
    assert.match(applyGuidePointSource, /CompanionGuidePointOverlayPresenter\.application/);
    assert.match(applyGuidePointSource, /detectedElementBubbleText = state\.bubbleText/);
    assert.match(applyGuidePointSource, /detectedElementPointLabel = state\.pointLabel/);
    assert.match(applyGuidePointSource, /detectedElementMissionAlignment = state\.missionAlignment/);
    assert.match(applyGuidePointSource, /detectedElementScreenLocation = state\.screenLocation/);
    assert.match(applyGuidePointSource, /detectedElementDisplayFrame = state\.displayFrame/);
    assert.match(applyGuidePointSource, /detectedElementTargetRevision = state\.targetRevision/);
    assert.match(applyGuidePointSource, /CompanionGuidePointOverlayPresenter\.diagnosticEvent\(for: rejection\)/);
    assert.doesNotMatch(applyGuidePointSource, /GuidePointOverlayPlacementCalculator\.placement/);
    assert.doesNotMatch(applyGuidePointSource, /detectedElementTargetRevision = UUID\(\)/);
    assert.doesNotMatch(managerSource, /func applyGuidePoint\(/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointOverlayPresenter\.application/);
    assert.match(guidePointOverlayPlacementSource, /enum GuidePointOverlayPlacementCalculator/);
    assert.match(guidePointOverlayPlacementSource, /case targetScreenUnavailable/);
    assert.match(guidePointOverlayPlacementSource, /case pointOutsideScreenshot/);
    assert.match(guidePointOverlayPlacementSource, /targetX\.isFinite/);
    assert.match(guidePointOverlayPlacementSource, /targetY\.isFinite/);
    assert.match(guidePointOverlayPlacementSource, /targetX <= screenshotWidth/);
    assert.match(guidePointOverlayPlacementSource, /targetY <= screenshotHeight/);
    assert.match(guidePointOverlayPlacementSource, /guidePoint\.screenNumber/);
    assert.match(guidePointOverlayPlacementSource, /isCursorScreen/);
    assert.match(guidePointOverlayPlacementSource, /spiderSanitizedShortDialogue/);
    assert.match(guidePointOverlayPlacementSource, /guidePoint\.label\?\.spiderSanitizedSingleLine/);
    assert.match(guidePointOverlayPlacementSource, /guidePoint\.missionAlignment\?\.spiderSanitizedSingleLine/);
    assert.match(guidePointOverlayPresenterSource, /struct CompanionGuidePointOverlayState: Equatable/);
    assert.match(guidePointOverlayPresenterSource, /enum CompanionGuidePointOverlayApplication: Equatable/);
    assert.match(guidePointOverlayPresenterSource, /enum CompanionGuidePointOverlayPresenter/);
    assert.match(guidePointOverlayPresenterSource, /GuidePointOverlayPlacementCalculator\.placement/);
    assert.match(guidePointOverlayPresenterSource, /targetRevision: makeTargetRevision\(\)/);
    assert.match(guidePointOverlayPresenterSource, /guide point ignored because target screen was unavailable/);
    assert.match(guidePointOverlayPresenterSource, /guide point ignored because coordinates were outside screenshot/);
    assert.match(groundingTelemetryRecorderSource, /SpiderDiagnostics\.guidePointIgnored\(reason\)/);
    assert.match(diagnosticsSource, /static func guidePointIgnored\(_ reason: SpiderGuidePointRejectionReason\)/);
    assert.match(diagnosticsSource, /guide point ignored: \\\(reason\.rawValue\)/);
    assert.match(visionGuideActionsSource, /shouldRejectRepeatedFailedPoint/);
    assert.doesNotMatch(managerSource, /shouldRejectRepeatedFailedPoint/);
    assert.match(guidedSetupActionsSource, /pendingPointOutcome/);
    assert.match(guidedSetupActionsSource, /trackGuidePointOutcome/);
    assert.match(debugActionsSource, /#if DEBUG/);
    assert.match(debugActionsSource, /func previewMissionPointerOverlay\(\)/);
    assert.match(debugActionsSource, /debug mission pointer preview shown/);
    assert.doesNotMatch(managerSource, /func previewMissionPointerOverlay\(\)/);
    assert.match(guidePointSafetyPolicySource, /resolvedScreenState == \.recognized/);
    assert.match(guidePointSafetyPolicySource, /guideResponse\.screenConfidence == \.high/);
    assert.match(guidePointSafetyPolicySource, /!guideResponse\.requiresManualConfirmation/);
    assert.match(guidePointSafetyPolicySource, /restrictedScreenIds\.contains\(screenId\)/);
    assert.match(guidePointSafetyPolicySource, /restrictedStageIds\.contains\(stageId\)/);
    assert.match(guidePointSafetyPolicySource, /unsafePointLabelFragments\.contains/);
    assert.match(visionGuideRequestRunnerSource, /trackGuideScreenClassified/);
    assert.match(groundingTelemetryRecorderSource, /trackGuidePointRejected/);
    assert.match(guidedSetupActionsSource, /trackGuideLoadingReclassification/);
    assert.match(guidedSetupActionsSource, /trackGuideUnknownScreen/);
    assert.doesNotMatch(analyticsSource, /enum SpiderGuidePointRejectionReason: String/);
    assert.match(guidePointRejectionSource, /enum SpiderGuidePointRejectionReason: String/);
    assert.match(guidePointRejectionSource, /case unrecognizedScreen = "unrecognized_screen"/);
    assert.match(guidePointRejectionSource, /case lowConfidence = "low_confidence"/);
    assert.match(guidePointRejectionSource, /case manualConfirmationRequired = "manual_confirmation_required"/);
    assert.match(guidePointRejectionSource, /case unsafeLabel = "unsafe_label"/);
    assert.match(guidePointRejectionSource, /case missingMissionAlignment = "missing_mission_alignment"/);
    assert.match(guidePointRejectionSource, /case sensitiveEvidence = "sensitive_evidence"/);
    assert.match(guidePointRejectionSource, /case pointOutsideRegion = "point_outside_region"/);
    assert.match(guidePointRejectionSource, /case targetOccluded = "target_occluded"/);
    assert.match(guidePointRejectionSource, /case outcomeFailed = "outcome_failed"/);
    assert.match(guidePointRejectionSource, /case sensitiveGroundingText = "sensitive_grounding_text"/);
    assert.match(guidePointRejectionSource, /case sensorFusionContradicted = "sensor_fusion_contradicted"/);
    assert.match(analyticsSource, /guide_point_rejected/);
    assert.match(analyticsSource, /guide_point_outcome/);
    assert.match(outcomeContractsSource, /enum GuidedPointOutcomeStatus: String/);
    assert.match(outcomeContractsSource, /case confirmed = "outcome_confirmed"/);
    assert.match(outcomeContractsSource, /case failed = "outcome_failed"/);
    assert.doesNotMatch(guidedSetupSessionSource, /enum GuidedPointOutcomeStatus: String/);
    assert.match(guidedSetupSessionSource, /evaluatePendingPointOutcome/);
    assert.match(guidedSetupSessionSource, /shouldRejectRepeatedFailedPoint/);
    assert.match(guidedSetupSessionSource, /semanticSignature/);
    assert.match(analyticsSource, /deliberately never sends transcripts, AI\s+\/\/  responses, screenshots, email addresses, or prompts/);
    assert.match(overlaySource, /GuideClickTargetView/);
    assert.match(overlaySource, /targetMarkerPosition/);
    assert.match(overlaySource, /targetMarkerMissionAlignment/);
    assert.match(overlaySource, /targetMarkerPostReturnHoldNanoseconds/);
    assert.match(overlaySource, /scheduleTargetMarkerDismissal/);
    assert.match(overlaySource, /onChange\(of: companionManager\.detectedElementTargetRevision\)/);
    assert.match(overlaySource, /allowsHitTesting\(false\)/);
    assert.match(overlaySource, /SpiderCursorBubbleView<SizePreferenceKey>/);
    assert.match(overlaySource, /SpiderCursorBubbleView<NavigationBubbleSizePreferenceKey>/);
    assert.doesNotMatch(overlaySource, /class OverlayWindow: NSWindow/);
    assert.doesNotMatch(overlaySource, /class OverlayWindowManager/);
    assert.match(overlayWindowShellSource, /final class OverlayWindow: NSWindow/);
    assert.match(overlayWindowShellSource, /ignoresMouseEvents = true/);
    assert.match(overlayWindowShellSource, /level = \.screenSaver/);
    assert.match(overlayWindowManagerSource, /final class OverlayWindowManager/);
    assert.match(overlayWindowManagerSource, /SpiderCursorView/);
    assert.match(overlayWindowManagerSource, /window\.orderFrontRegardless\(\)/);
    assert.match(cursorNavigationModeSource, /enum BuddyNavigationMode/);
    assert.match(cursorNavigationModeSource, /case followingCursor/);
    assert.match(cursorNavigationModeSource, /case navigatingToTarget/);
    assert.match(cursorNavigationModeSource, /case pointingAtTarget/);
    assert.match(cursorBubbleSource, /struct SpiderCursorBubbleView<SizeKey: PreferenceKey>: View/);
    assert.match(cursorBubbleSource, /\.preference\(key: SizeKey\.self, value: geometry\.size\)/);
    assert.match(guideTargetSource, /struct GuideClickTargetView: View/);
    assert.match(guideTargetSource, /clickDotSize/);
    assert.match(guideTargetSource, /#Preview\("Mission pointer target"\)/);
    assert.match(previewRenderScript, /GuideClickTargetView\.swift/);
    assert.match(previewRenderScript, /render_mission_pointer_preview\.swift/);
  });
}
