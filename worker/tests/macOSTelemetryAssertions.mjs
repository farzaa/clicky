import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSTelemetryAssertions({ test, workerRoot }) {
  test("macOS grounding telemetry is privacy-safe and hash-only", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManager.swift"),
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
    const analyticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderAnalytics.swift"),
      "utf8"
    );
    const permissionStateSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPermissionState.swift"),
      "utf8"
    );
    const permissionTelemetryRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPermissionTelemetryRecorder.swift"),
      "utf8"
    );
    const groundingAnalyticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingAnalytics.swift"),
      "utf8"
    );
    const groundingTelemetryEmitterSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetryEmitter.swift"),
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
    const groundingTelemetrySanitizerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetrySanitizer.swift"),
      "utf8"
    );
    const groundingPrivacySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingPrivacy.swift"),
      "utf8"
    );
    const groundingTelemetryRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryRecorder.swift"),
      "utf8"
    );
    const groundingTelemetryMetadataSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryMetadata.swift"),
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
    const visionGuideRequestRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionVisionGuideRequestRunner.swift"),
      "utf8"
    );
    const onboardingDemoGuideRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionOnboardingDemoGuideRunner.swift"),
      "utf8"
    );
    const guidePointTelemetrySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePointTelemetryRecorder.swift"),
      "utf8"
    );
    const guidePipelineClockSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuidePipelineClock.swift"),
      "utf8"
    );
    const sessionStoreSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderSessionStore.swift"),
      "utf8"
    );
    const telemetryEventSource = groundingTelemetrySource.slice(
      groundingTelemetrySource.indexOf("struct SpiderGroundingTelemetryEvent")
    );
    const telemetryPayloadSource = groundingTelemetryPayloadBuilderSource.slice(
      groundingTelemetryPayloadBuilderSource.indexOf("enum SpiderGroundingTelemetryPayloadBuilder")
    );

    assert.match(groundingTelemetrySource, /enum SpiderGroundingTelemetryEventName: String/);
    assert.match(groundingTelemetrySource, /case frameAnalyzed = "grounding_frame_analyzed"/);
    assert.match(groundingTelemetrySource, /case pointAccepted = "grounding_point_accepted"/);
    assert.match(groundingTelemetrySource, /case pointRejected = "grounding_point_rejected"/);
    assert.match(groundingTelemetrySource, /case outcomeEvaluated = "grounding_outcome_evaluated"/);
    assert.match(groundingTelemetrySource, /case pointSuppressed = "grounding_point_suppressed"/);
    assert.match(groundingTelemetrySource, /case sensorFusionEvaluated = "grounding_sensor_fusion_evaluated"/);
    assert.match(groundingTelemetrySource, /case shadowCandidate = "grounding_shadow_candidate"/);
    assert.match(groundingTelemetrySource, /struct SpiderGroundingTelemetryEvent: Equatable/);
    assert.match(groundingTelemetrySource, /SpiderGroundingTelemetryPayloadBuilder\.sanitizedPayload\(for: self\)/);
    assert.doesNotMatch(telemetryEventSource, /allowedPayloadKeys\.contains/);
    assert.match(groundingTelemetryPayloadBuilderSource, /enum SpiderGroundingTelemetryPayloadBuilder/);
    assert.match(groundingTelemetryPayloadBuilderSource, /static func sanitizedPayload\(for event: SpiderGroundingTelemetryEvent\)/);
    assert.match(groundingTelemetryPayloadBuilderSource, /allowedPayloadKeys\.contains/);
    assert.match(groundingTelemetrySanitizerSource, /enum SpiderGroundingTelemetrySanitizer/);
    assert.match(groundingTelemetrySanitizerSource, /allowedPayloadKeys: Set<String>/);
    assert.match(groundingTelemetrySanitizerSource, /safeIdentifierPattern/);
    assert.doesNotMatch(groundingTelemetrySource, /private static let safeIdentifierPattern/);
    assert.doesNotMatch(analyticsSource, /trackGroundingFrameAnalyzed/);
    assert.doesNotMatch(analyticsSource, /trackGroundingPointAccepted/);
    assert.doesNotMatch(analyticsSource, /trackGroundingPointRejected/);
    assert.doesNotMatch(analyticsSource, /trackGroundingOutcomeEvaluated/);
    assert.doesNotMatch(analyticsSource, /trackGroundingPointSuppressed/);
    assert.match(analyticsSource, /enum SpiderPermissionTelemetryName: String, CaseIterable, Equatable/);
    assert.match(analyticsSource, /case accessibility = "accessibility"/);
    assert.match(analyticsSource, /case screenRecording = "screen_recording"/);
    assert.match(analyticsSource, /case microphone = "microphone"/);
    assert.match(analyticsSource, /case screenContent = "screen_content"/);
    assert.match(analyticsSource, /trackPermissionGranted\(_ permission: SpiderPermissionTelemetryName\)/);
    assert.doesNotMatch(analyticsSource, /trackPermissionGranted\(permission: String\)/);
    assert.match(permissionStateSource, /var telemetryName: SpiderPermissionTelemetryName/);
    assert.match(permissionStateSource, /promptPermissionGrantTelemetryNames/);
    assert.doesNotMatch(permissionStateSource, /analyticsName: String/);
    assert.match(permissionTelemetryRecorderSource, /SpiderAnalytics\.trackPermissionGranted\(permission\.telemetryName\)/);
    assert.doesNotMatch(permissionTelemetryRecorderSource, /permission\.analyticsName/);
    assert.match(groundingAnalyticsSource, /extension SpiderAnalytics/);
    assert.match(groundingAnalyticsSource, /trackGroundingFrameAnalyzed/);
    assert.match(groundingAnalyticsSource, /trackGroundingPointAccepted/);
    assert.match(groundingAnalyticsSource, /trackGroundingPointRejected/);
    assert.match(groundingAnalyticsSource, /trackGroundingOutcomeEvaluated/);
    assert.match(groundingAnalyticsSource, /trackGroundingPointSuppressed/);
    assert.match(groundingAnalyticsSource, /trackGroundingSensorFusionEvaluated/);
    assert.match(groundingAnalyticsSource, /trackGroundingShadowCandidate/);
    assert.match(groundingTelemetryEmitterSource, /enum SpiderGroundingTelemetryEmitter/);
    assert.match(groundingTelemetryEmitterSource, /groundingTelemetryEnabledDefaultsKey/);
    assert.match(groundingTelemetryEmitterSource, /static var isEnabled: Bool/);
    assert.match(groundingTelemetryEmitterSource, /static func emit\(_ event: SpiderGroundingTelemetryEvent\)/);
    assert.match(groundingTelemetryEmitterSource, /SpiderAnalytics\.logMetric/);
    assert.doesNotMatch(groundingAnalyticsSource, /groundingTelemetryEnabledDefaultsKey/);
    assert.doesNotMatch(analyticsSource, /HMAC<SHA256>\.authenticationCode/);
    assert.match(groundingPrivacySource, /enum SpiderGroundingPrivacy/);
    assert.match(groundingPrivacySource, /HMAC<SHA256>\.authenticationCode/);
    assert.match(groundingPrivacySource, /SpiderSessionStore\.loadOrCreateGroundingTelemetrySalt/);
    assert.match(groundingPrivacySource, /targetElementIdHash\(for rawTargetElementId: String\?\)/);

    for (const allowedField of [
      "platform",
      "stageId",
      "screenState",
      "screenConfidence",
      "semanticSignature",
      "targetElementIdHash",
      "targetFingerprint",
      "targetFingerprintCompatibility",
      "actionRisk",
      "screenType",
      "stageType",
      "journeyTransition",
      "journeyAllowsDot",
      "calibrationDecision",
      "fastPathDecision",
      "dotSuppressedByLatency",
      "requiresPreDotVerification",
      "preDotVerificationReason",
      "wouldHaveShownDot",
      "expectedOutcome",
      "rejectionReason",
      "outcomeStatus",
      "latencyMs",
      "screenshotCaptureLatencyMs",
      "visionRequestLatencyMs",
      "workerValidationLatencyMs",
      "preDotVerificationLatencyMs",
      "timeToDotMs",
      "sensorFusionLatencyMs",
      "ocrLatencyMs",
      "axLatencyMs",
      "browserMetadataLatencyMs",
      "totalPointDecisionLatencyMs",
      "screenChanged",
      "pollIndex",
      "retryAllowed",
      "maxAttemptsForSameTarget",
      "requiresNewSemanticSignature",
      "requiresTargetReappearance",
      "retryReason",
      "requiresUserConfirmationAfterFailure",
      "doNotRepeatUntilSignatureChanges",
      "fusionDecision",
      "fusionShouldBlockPoint",
      "confirmedSources",
      "contradictedSources",
      "contradictionReason",
      "timestamp",
      "appVersion",
      "groundingSchemaVersion",
    ]) {
      assert.match(telemetryPayloadSource, new RegExp(`"${allowedField}"`));
    }

    for (const forbiddenField of [
      "screenshot",
      "transcript",
      "prompt",
      "responseText",
      "visibleText",
      "point.label",
      "missionAlignment",
      "nearestText",
      "evidence",
      "targetElementId",
      "ocrText",
      "rawOCRText",
      "axValue",
      "axTitle",
      "axLabel",
      "domText",
      "browserText",
    ]) {
      assert.doesNotMatch(
        telemetryPayloadSource,
        new RegExp(`"${forbiddenField.replace(".", "\\.")}"`)
      );
    }

    assert.match(sessionStoreSource, /groundingTelemetrySaltAccount = "spider\.grounding-telemetry-salt"/);
    assert.match(sessionStoreSource, /groundingTelemetrySaltByteCount = 32/);
    assert.match(sessionStoreSource, /loadOrCreateGroundingTelemetrySalt/);
    assert.match(sessionStoreSource, /SecRandomCopyBytes/);
    assert.match(sessionStoreSource, /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/);
    assert.match(groundingTelemetryMetadataSource, /struct GroundingGuideResponseMetadata: Equatable/);
    assert.match(groundingTelemetryMetadataSource, /struct GroundingPointAcceptanceMetadata: Equatable/);
    assert.match(groundingTelemetryMetadataSource, /struct GroundingPointRejectionMetadata: Equatable/);
    assert.match(groundingTelemetryMetadataSource, /enum GroundingTelemetryMetadataBuilder/);
    assert.match(groundingTelemetryRecorderSource, /typealias GuideResponseMetadata = GroundingGuideResponseMetadata/);
    assert.match(groundingTelemetryRecorderSource, /typealias PointAcceptanceMetadata = GroundingPointAcceptanceMetadata/);
    assert.match(groundingTelemetryRecorderSource, /typealias PointRejectionMetadata = GroundingPointRejectionMetadata/);
    assert.match(groundingTelemetryRecorderSource, /static func guideResponseMetadata\(/);
    assert.match(groundingTelemetryRecorderSource, /static func pointAcceptanceMetadata\(/);
    assert.match(groundingTelemetryRecorderSource, /GroundingTelemetryMetadataBuilder\.guideResponseMetadata/);
    assert.match(groundingTelemetryRecorderSource, /GroundingTelemetryMetadataBuilder\.pointAcceptanceMetadata/);
    assert.match(groundingTelemetryRecorderSource, /GroundingTelemetryMetadataBuilder\.pointRejectionMetadata/);
    assert.match(groundingTelemetryRecorderSource, /GroundingTelemetryMetadataBuilder\.shouldTrackShadowCandidate/);
    assert.match(groundingTelemetryMetadataSource, /screenConfidence: guideResponse\.screenConfidence \?\? guideResponse\.confidence/);
    assert.match(groundingTelemetryRecorderSource, /static func recordFrameAnalyzed\(/);
    assert.match(groundingTelemetryRecorderSource, /static func recordPointAccepted\(/);
    assert.match(groundingTelemetryRecorderSource, /static func recordPointSuppressed\(/);
    assert.match(groundingTelemetryRecorderSource, /static func recordSensorFusionEvaluated\(/);
    assert.match(groundingTelemetryRecorderSource, /static func recordOutcomeEvaluated\(/);
    assert.match(visionGuideRequestRunnerSource, /GroundingTelemetryRecorder\.guideResponseMetadata/);
    assert.match(onboardingDemoGuideRunnerSource, /GroundingTelemetryRecorder\.guideResponseMetadata/);
    assert.doesNotMatch(managerSource, /GroundingTelemetryRecorder\.guideResponseMetadata/);
    assert.match(guidePointTelemetrySource, /GroundingTelemetryRecorder\.pointAcceptanceMetadata/);
    assert.match(visionGuideRequestRunnerSource, /GroundingTelemetryRecorder\.recordFrameAnalyzed/);
    assert.match(onboardingDemoGuideRunnerSource, /GroundingTelemetryRecorder\.recordFrameAnalyzed/);
    assert.doesNotMatch(managerSource, /GroundingTelemetryRecorder\.recordFrameAnalyzed/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointTelemetryRecorder\.recordAccepted/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointTelemetryRecorder\.recordSuppressed/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointTelemetryRecorder\.recordAccepted/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointTelemetryRecorder\.recordSuppressed/);
    assert.doesNotMatch(managerSource, /GroundingTelemetryRecorder\.recordPointAccepted/);
    assert.doesNotMatch(managerSource, /GroundingTelemetryRecorder\.recordPointSuppressed/);
    assert.match(guidePointTelemetrySource, /GroundingTelemetryRecorder\.recordPointAccepted/);
    assert.match(guidePointTelemetrySource, /GroundingTelemetryRecorder\.recordPointSuppressed/);
    assert.doesNotMatch(guidePointEvaluatorSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(guidePointSensorFusionRunnerSource, /GroundingTelemetryRecorder\.recordSensorFusionEvaluated/);
    assert.match(guidedSetupActionsSource, /GroundingTelemetryRecorder\.recordOutcomeEvaluated/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackGroundingFrameAnalyzed/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackGroundingPointAccepted/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackGroundingPointSuppressed/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackGroundingSensorFusionEvaluated/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackGroundingOutcomeEvaluated/);
    assert.doesNotMatch(guidePointEvaluatorSource, /SpiderAnalytics\.trackGroundingSensorFusionEvaluated/);
    assert.match(groundingTelemetryRecorderSource, /trackGroundingPointRejected/);
    assert.match(groundingTelemetryRecorderSource, /trackGroundingOutcomeEvaluated/);
    assert.match(groundingTelemetryRecorderSource, /trackGroundingShadowCandidate/);
    assert.match(guidePipelineClockSource, /enum CompanionGuidePipelineClock/);
    assert.match(guidePipelineClockSource, /static func elapsedMilliseconds/);
    assert.match(visionGuideActionsSource, /CompanionGuidePipelineClock\.elapsedMilliseconds/);
    assert.doesNotMatch(managerSource, /CompanionGuidePipelineClock\.elapsedMilliseconds/);
    assert.doesNotMatch(guidePointEvaluatorSource, /CompanionGuidePipelineClock\.elapsedMilliseconds/);
    assert.match(guidePointSensorFusionRunnerSource, /CompanionGuidePipelineClock\.elapsedMilliseconds/);
    assert.doesNotMatch(managerSource, /private static func elapsedMilliseconds/);
    assert.doesNotMatch(guidePointEvaluatorSource, /private static func elapsedMilliseconds/);
  });
}
