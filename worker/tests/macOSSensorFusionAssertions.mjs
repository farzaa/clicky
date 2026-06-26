import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSSensorFusionAssertions({ test, workerRoot }) {
  test("macOS sensor fusion confirms or blocks Vision-selected dots without leaking text", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManager.swift"),
      "utf8"
    );
    const analyticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderAnalytics.swift"),
      "utf8"
    );
    const groundingTelemetrySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetry.swift"),
      "utf8"
    );
    const groundingTelemetryPayloadBuilderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetryPayloadBuilder.swift"),
      "utf8"
    );
    const guidePointRejectionSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuidePointRejectionReason.swift"),
      "utf8"
    );
    const openAISource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OpenAIAPI.swift"),
      "utf8"
    );
    const guideGroundingContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuideGroundingContracts.swift"),
      "utf8"
    );
    const sensorFusionSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingSensorFusion.swift"),
      "utf8"
    );
    const sensorFusionSignalCollectorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingSensorFusionSignalCollector.swift"),
      "utf8"
    );
    const sensorFusionTimingSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingSensorFusionTiming.swift"),
      "utf8"
    );
    const sensorFusionDecisionResolverSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingSensorFusionDecisionResolver.swift"),
      "utf8"
    );
    const contextClassifierSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingContextClassifier.swift"),
      "utf8"
    );
    const dotEligibilityPolicySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingDotEligibilityPolicy.swift"),
      "utf8"
    );
    const pointProjectorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingPointProjector.swift"),
      "utf8"
    );
    const regionQualitySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingRegionQualityEvaluator.swift"),
      "utf8"
    );
    const cursorMetadataSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingCursorMetadataSensor.swift"),
      "utf8"
    );
    const localOCRSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingLocalOCRSensor.swift"),
      "utf8"
    );
    const accessibilitySensorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingAccessibilitySensor.swift"),
      "utf8"
    );
    const sensorFusionContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingSensorFusionContracts.swift"),
      "utf8"
    );
    const guidePointSafetySource = readFileSync(
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
    const onboardingDemoGuideRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionOnboardingDemoGuideRunner.swift"),
      "utf8"
    );
    const onboardingActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerOnboardingActions.swift"),
      "utf8"
    );
    const visionGuideActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerVisionGuideActions.swift"),
      "utf8"
    );
    const preDotVerificationCoordinatorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPreDotVerificationCoordinator.swift"),
      "utf8"
    );
    const groundingTelemetryRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryRecorder.swift"),
      "utf8"
    );
    const targetIdentitySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTargetIdentity.swift"),
      "utf8"
    );
    const promptSource = readFileSync(path.join(workerRoot, "src", "visionGuidePrompt.ts"), "utf8");
    const promptContractsSource = readFileSync(
      path.join(workerRoot, "src", "visionGuidePromptContracts.ts"),
      "utf8"
    );
    const contractSource = readFileSync(path.join(workerRoot, "src", "guideResponseContract.ts"), "utf8");
    const telemetryEventSource = groundingTelemetrySource.slice(
      groundingTelemetrySource.indexOf("struct SpiderGroundingTelemetryEvent")
    );
    const telemetryPayloadSource = groundingTelemetryPayloadBuilderSource.slice(
      groundingTelemetryPayloadBuilderSource.indexOf("enum SpiderGroundingTelemetryPayloadBuilder")
    );

    assert.match(sensorFusionContractsSource, /enum GroundingSensorFusionDecisionKind: String, Equatable/);
    assert.match(sensorFusionContractsSource, /case confirmed/);
    assert.match(sensorFusionContractsSource, /case weaklyConfirmed = "weakly_confirmed"/);
    assert.match(sensorFusionContractsSource, /case inconclusive/);
    assert.match(sensorFusionContractsSource, /case contradicted/);
    assert.match(sensorFusionContractsSource, /case unavailable/);
    assert.match(sensorFusionContractsSource, /enum GroundingAuxiliarySignalSource: String/);
    assert.match(sensorFusionContractsSource, /case localOCR = "local_ocr"/);
    assert.match(sensorFusionContractsSource, /case macOSAccessibility = "macos_accessibility"/);
    assert.match(sensorFusionContractsSource, /case browserMetadata = "browser_metadata"/);
    assert.match(sensorFusionContractsSource, /case cursorMetadata = "cursor_metadata"/);
    assert.match(sensorFusionContractsSource, /struct GroundingSensorFusionEvidence: Equatable/);
    assert.match(sensorFusionContractsSource, /targetFingerprint: TargetFingerprint\?/);
    assert.match(sensorFusionContractsSource, /regionQuality: RegionQuality/);
    assert.match(sensorFusionContractsSource, /struct GroundingAuxiliarySignal: Equatable/);
    assert.match(sensorFusionContractsSource, /struct GroundingSensorFusionDecision: Equatable/);
    assert.match(sensorFusionContractsSource, /struct GroundingSensorFusionPolicy: Equatable/);
    assert.match(sensorFusionContractsSource, /blockedTargetOverlapTolerancePixels/);
    assert.match(sensorFusionContractsSource, /ocrStrongMismatchMinimumCandidates/);
    assert.match(sensorFusionContractsSource, /ocrStrongMismatchMinimumAverageConfidence/);
    assert.match(sensorFusionContractsSource, /localOCRLatencyCutoffMs/);
    assert.match(sensorFusionContractsSource, /browserMetadataLatencyCutoffMs/);
    assert.match(sensorFusionContractsSource, /struct GroundingSensorFusionLatency: Equatable/);
    assert.match(sensorFusionContractsSource, /sensorFusionLatencyMs/);
    assert.match(sensorFusionContractsSource, /ocrLatencyMs/);
    assert.match(sensorFusionContractsSource, /axLatencyMs/);
    assert.match(sensorFusionContractsSource, /browserMetadataLatencyMs/);
    assert.doesNotMatch(sensorFusionSource, /enum GroundingSensorFusionDecisionKind: String, Equatable/);
    assert.doesNotMatch(sensorFusionSource, /struct GroundingSensorFusionPolicy: Equatable/);
    assert.match(contextClassifierSource, /struct GroundingContextClassification: Equatable/);
    assert.match(contextClassifierSource, /enum GroundingContextClassifier/);
    assert.match(contextClassifierSource, /static func classify\(/);
    assert.match(contextClassifierSource, /billingRiskFragments/);
    assert.match(contextClassifierSource, /publishRiskFragments/);
    assert.match(contextClassifierSource, /spendRiskFragments/);
    assert.match(contextClassifierSource, /reviewPublishBoundary/);
    assert.match(contextClassifierSource, /GroundingJourneyDecision/);
    assert.match(contextClassifierSource, /transition: \.reviewToManualBoundary/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingContextClassifier\.classify/);
    assert.doesNotMatch(sensorFusionSource, /billingRiskFragments/);
    assert.doesNotMatch(sensorFusionSource, /private static func actionRisk/);
    assert.doesNotMatch(sensorFusionSource, /private static func screenType/);
    assert.doesNotMatch(sensorFusionSource, /private static func journeyDecision/);
    assert.match(dotEligibilityPolicySource, /enum GroundingDotEligibilityPolicy/);
    assert.match(dotEligibilityPolicySource, /static func isFastPathEligible/);
    assert.match(dotEligibilityPolicySource, /static func fastPathDecision/);
    assert.match(dotEligibilityPolicySource, /static func shouldSuppressDotForLatency/);
    assert.match(dotEligibilityPolicySource, /static func policyContradictions/);
    assert.match(dotEligibilityPolicySource, /static func calibrationDecision/);
    assert.match(dotEligibilityPolicySource, /static func preDotVerificationReasons/);
    assert.match(dotEligibilityPolicySource, /targetPresenceAllowsFastPath/);
    assert.match(dotEligibilityPolicySource, /fastPathDecision != \.accepted/);
    assert.match(dotEligibilityPolicySource, /latencyExceeded/);
    assert.match(dotEligibilityPolicySource, /GroundingSensorFusionContradiction\.ocrTextMismatch/);
    assert.match(sensorFusionSource, /GroundingSensorFusionSignalCollector\.collect/);
    assert.match(sensorFusionSignalCollectorSource, /enum GroundingSensorFusionSignalCollector/);
    assert.match(sensorFusionSignalCollectorSource, /struct GroundingSensorFusionObservation/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingDotEligibilityPolicy\.isFastPathEligible/);
    assert.match(sensorFusionSource, /GroundingDotEligibilityPolicy\.preDotVerificationReasons/);
    assert.doesNotMatch(sensorFusionSource, /private static func isFastPathEligible/);
    assert.doesNotMatch(sensorFusionSource, /private static func shouldSuppressDotForLatency/);
    assert.doesNotMatch(sensorFusionSource, /private static func calibrationDecision/);
    assert.doesNotMatch(sensorFusionSource, /private static func preDotVerificationReasons/);
    assert.match(sensorFusionSource, /static func evaluate\(/);
    assert.match(sensorFusionSource, /GroundingSensorFusionDecisionResolver\.resolve/);
    assert.match(sensorFusionDecisionResolverSource, /enum GroundingSensorFusionDecisionResolver/);
    assert.match(sensorFusionDecisionResolverSource, /static func resolve\(/);
    assert.match(sensorFusionDecisionResolverSource, /ocrOnlyContradiction/);
    assert.match(sensorFusionDecisionResolverSource, /evidence\.calibrationDecision == \.strongBlock/);
    assert.match(sensorFusionDecisionResolverSource, /policy\.blockOnStrongContradiction/);
    assert.doesNotMatch(sensorFusionSource, /private static func decision/);
    assert.doesNotMatch(sensorFusionSource, /ocrOnlyContradiction/);
    assert.match(sensorFusionTimingSource, /enum GroundingSensorFusionTiming/);
    assert.match(sensorFusionTimingSource, /static func measureSignal/);
    assert.match(sensorFusionTimingSource, /static func measureValue/);
    assert.match(sensorFusionTimingSource, /static func measureOptional/);
    assert.match(sensorFusionTimingSource, /static func signalAfterApplyingLatencyCutoff/);
    assert.match(sensorFusionTimingSource, /static func elapsedMilliseconds/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingSensorFusionTiming\.measureSignal/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingSensorFusionTiming\.signalAfterApplyingLatencyCutoff/);
    assert.doesNotMatch(sensorFusionSource, /private struct MeasuredValue/);
    assert.doesNotMatch(sensorFusionSource, /private static func measureSignal/);
    assert.doesNotMatch(sensorFusionSource, /private static func elapsedMilliseconds/);

    assert.match(sensorFusionSignalCollectorSource, /GroundingPointProjector\.projection/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingRegionQualityEvaluator\.evaluate/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingCursorMetadataSensor\.signal/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingLocalOCRSensor\.signal/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingAccessibilitySensor\.snapshot/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingAccessibilitySensor\.browserMetadata\(from:/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingAccessibilitySensor\.accessibilitySignal/);
    assert.match(sensorFusionSignalCollectorSource, /GroundingAccessibilitySensor\.browserMetadataSignal/);
    assert.doesNotMatch(sensorFusionSource, /VNRecognizeTextRequest/);
    assert.doesNotMatch(sensorFusionSource, /AXUIElementCopyElementAtPosition/);
    assert.doesNotMatch(sensorFusionSource, /private static func cursorMetadataSignal/);
    assert.doesNotMatch(sensorFusionSource, /private static func regionQuality/);

    assert.match(pointProjectorSource, /struct GroundingPointProjection/);
    assert.match(pointProjectorSource, /enum GroundingPointProjector/);
    assert.match(pointProjectorSource, /static func projection/);
    assert.match(regionQualitySource, /enum GroundingRegionQualityEvaluator/);
    assert.match(regionQualitySource, /static func evaluate/);
    assert.match(regionQualitySource, /blockedTargetOverlapTolerancePixels/);
    assert.match(cursorMetadataSource, /enum GroundingCursorMetadataSensor/);
    assert.match(cursorMetadataSource, /static func signal/);
    assert.match(cursorMetadataSource, /pointOutsideTargetRegion/);
    assert.match(cursorMetadataSource, /blockedTargetOverlap/);
    assert.match(cursorMetadataSource, /targetConfidenceLow/);
    assert.match(cursorMetadataSource, /targetAffordanceNotClickable/);
    assert.match(cursorMetadataSource, /targetFingerprintMissing/);
    assert.match(cursorMetadataSource, /targetStaleAfterScreenChange/);
    assert.match(cursorMetadataSource, /regionConfidenceLow/);
    assert.match(cursorMetadataSource, /regionImplausible/);
    assert.match(cursorMetadataSource, /targetOccluded/);
    assert.match(localOCRSource, /enum GroundingLocalOCRSensor/);
    assert.match(localOCRSource, /VNRecognizeTextRequest/);
    assert.match(localOCRSource, /ocrTextMismatch/);
    assert.match(localOCRSource, /containsSensitiveComparableText/);
    assert.match(accessibilitySensorSource, /enum GroundingAccessibilitySensor/);
    assert.match(accessibilitySensorSource, /AXUIElementCopyElementAtPosition/);
    assert.match(accessibilitySensorSource, /accessibilityElementDisabled/);
    assert.match(accessibilitySensorSource, /accessibilityElementNotInteractive/);
    assert.match(sensorFusionContractsSource, /struct GroundingBrowserMetadata: Equatable/);
    assert.match(sensorFusionContractsSource, /enum GroundingBrowserRoleCategory: String, Equatable/);
    assert.match(sensorFusionContractsSource, /GroundingBrowserMetadataSource/);
    assert.match(accessibilitySensorSource, /GroundingBrowserMetadata/);
    assert.match(accessibilitySensorSource, /roleCategory/);
    assert.match(accessibilitySensorSource, /elementInteractable/);
    assert.match(accessibilitySensorSource, /browserElementDisabled/);
    assert.match(accessibilitySensorSource, /browserElementHidden/);
    assert.match(accessibilitySensorSource, /browserElementCovered/);
    assert.match(sensorFusionSignalCollectorSource, /TargetFingerprint\.make/);
    assert.match(targetIdentitySource, /extension TargetFingerprint/);
    assert.match(targetIdentitySource, /static func make\(/);
    assert.match(targetIdentitySource, /targetFingerprintHash/);
    assert.match(targetIdentitySource, /extension RegionStability/);
    assert.match(targetIdentitySource, /extension SpiderGuideSemanticGrounding/);
    assert.match(targetIdentitySource, /func target\(matching point: SpiderGuidePoint\)/);
    assert.match(targetIdentitySource, /func element\(matching target: SpiderGuideSemanticTarget\?\)/);

    assert.doesNotMatch(openAISource, /struct SpiderGuideRegion: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct SpiderGuideRegion: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct SpiderGuideSceneGraphElement: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct SpiderGuideSemanticTarget: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /let interactiveTargets: \[SpiderGuideSemanticTarget\]/);
    assert.match(guideGroundingContractsSource, /let blockedTargets: \[SpiderGuideSemanticTarget\]/);
    assert.match(guideGroundingContractsSource, /let region: SpiderGuideRegion\?/);

    assert.match(guidePointSafetySource, /enum InitialPointDecision: Equatable/);
    assert.match(guidePointSafetySource, /static func initialPointDecision\(/);
    assert.match(guidePointSafetySource, /case noPoint/);
    assert.match(guidePointSafetySource, /case rejected\(SpiderGuidePointRejectionReason\)/);
    assert.match(guidePointSafetySource, /case evaluable\(SpiderGuidePoint\)/);

    assert.match(guidePointEvaluatorSource, /enum CompanionGuidePointEvaluator/);
    assert.match(guidePointEvaluatorSource, /enum CompanionGuidePointSensorFusionRejectionStyle/);
    const firstRejectionGate = guidePointEvaluatorSource.indexOf("let initialPointDecision = SpiderGuidePointSafetyPolicy.initialPointDecision");
    const firstFusionEvaluation = guidePointEvaluatorSource.indexOf("CompanionGuidePointSensorFusionRunner.evaluate");
    assert.ok(firstRejectionGate > -1 && firstFusionEvaluation > firstRejectionGate);
    assert.match(guidePointEvaluatorSource, /var pointRejectionReason = initialPointDecision\.rejectionReason/);
    assert.match(guidePointEvaluatorSource, /pointRejectionReason == nil \{\s+let sensorFusionResult = await CompanionGuidePointSensorFusionRunner\.evaluate/s);
    assert.match(guidePointEvaluatorSource, /return \.sensorFusionContradicted/);
    assert.match(onboardingDemoGuideRunnerSource, /sensorFusionRejectionStyle: \.genericContradiction/);
    assert.doesNotMatch(managerSource, /sensorFusionRejectionStyle: \.genericContradiction/);
    assert.match(onboardingActionsSource, /pointRejectionReason == \.sensorFusionContradicted \{\s+clearGuidanceStatusBubble\(\)/s);
    assert.doesNotMatch(managerSource, /showGuidanceStatusBubble\(sensorFusionReason\)/);
    assert.match(visionGuideActionsSource, /sensorFusionDecision: sensorFusionDecision/);
    assert.doesNotMatch(guidePointEvaluatorSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(guidePointSensorFusionRunnerSource, /GroundingSensorFusion\.evaluate/);
    assert.match(guidePointSensorFusionRunnerSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(groundingTelemetryRecorderSource, /trackGroundingSensorFusionEvaluated/);
    assert.match(preDotVerificationCoordinatorSource, /struct CompanionPreDotVerificationResolution/);
    assert.match(preDotVerificationCoordinatorSource, /enum CompanionPreDotVerificationCoordinator/);
    assert.match(preDotVerificationCoordinatorSource, /rememberNegativeTarget/);
    assert.match(preDotVerificationCoordinatorSource, /resolvePreDotVerification/);
    assert.match(preDotVerificationCoordinatorSource, /preDotVerificationPending/);
    assert.match(visionGuideActionsSource, /CompanionPreDotVerificationCoordinator\.resolve/);
    assert.doesNotMatch(managerSource, /CompanionPreDotVerificationCoordinator\.resolve/);
    assert.doesNotMatch(managerSource, /guidedSetupSession\.rememberNegativeTarget/);
    assert.doesNotMatch(managerSource, /guidedSetupSession\.resolvePreDotVerification/);

    assert.match(groundingTelemetrySource, /case sensorFusionEvaluated = "grounding_sensor_fusion_evaluated"/);
    assert.doesNotMatch(analyticsSource, /case sensorFusionContradicted = "sensor_fusion_contradicted"/);
    assert.match(guidePointRejectionSource, /case sensorFusionContradicted = "sensor_fusion_contradicted"/);
    assert.match(telemetryEventSource, /sensorFusionDecision: GroundingSensorFusionDecision\?/);
    assert.match(telemetryPayloadSource, /"fusionDecision"/);
    assert.match(telemetryPayloadSource, /"confirmedSources"/);
    assert.match(telemetryPayloadSource, /"contradictedSources"/);
    assert.match(telemetryPayloadSource, /"contradictionReason"/);
    assert.match(telemetryPayloadSource, /"targetFingerprint"/);
    assert.match(telemetryPayloadSource, /"regionConfidence"/);
    assert.match(telemetryPayloadSource, /"regionPlausibility"/);
    assert.match(telemetryPayloadSource, /"sensorFusionLatencyMs"/);
    assert.match(telemetryPayloadSource, /"ocrLatencyMs"/);
    assert.match(telemetryPayloadSource, /"axLatencyMs"/);
    assert.match(telemetryPayloadSource, /"browserMetadataLatencyMs"/);

    for (const forbiddenField of [
      "ocrText",
      "rawOCRText",
      "recognizedText",
      "axValue",
      "axTitle",
      "axLabel",
      "domText",
      "browserText",
      "point.label",
      "missionAlignment",
      "nearestText",
      "evidence",
      "targetElementId",
    ]) {
      assert.doesNotMatch(
        telemetryPayloadSource,
        new RegExp(`"${forbiddenField.replace(".", "\\.")}"`)
      );
    }

    assert.match(contractSource, /sensor_fusion_contradicted/);
    assert.match(promptContractsSource, /Auxiliary sources can confirm or contradict Vision only/);
    assert.match(
      promptSource,
      /They cannot replace Vision, create a point, or make a low\/medium-confidence visual target safe/
    );
    assert.match(promptSource, /Browser metadata, when available, is categorical only/);
    assert.match(promptContractsSource, /tile_selected/);
    assert.match(promptContractsSource, /dropdown_opened/);
    assert.match(promptContractsSource, /modal_closed/);
    assert.match(promptContractsSource, /wizard_advanced/);
    assert.match(promptContractsSource, /warning_cleared/);
    assert.match(promptContractsSource, /field_focused/);
    assert.match(promptContractsSource, /button_disabled/);
  });
}
