const allowedEventNames = new Set([
  "grounding_frame_analyzed",
  "grounding_point_accepted",
  "grounding_point_rejected",
  "grounding_outcome_evaluated",
  "grounding_point_suppressed",
  "grounding_sensor_fusion_evaluated",
  "grounding_shadow_candidate",
]);

const allowedKeys = new Set([
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
  "fusionDecision",
  "fusionShouldBlockPoint",
  "confirmedSources",
  "contradictedSources",
  "contradictionReason",
  "regionConfidence",
  "regionSource",
  "regionStability",
  "regionPlausibility",
  "pointInsideRegionConfidence",
  "outcomeStatus",
  "expectedOutcome",
  "outcomeKind",
  "rejectionReason",
  "retryReason",
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
  "groundingSchemaVersion",
  "appVersion",
  "timestamp",
  "retryAllowed",
  "maxAttemptsForSameTarget",
  "requiresNewSemanticSignature",
  "requiresTargetReappearance",
  "requiresUserConfirmationAfterFailure",
  "doNotRepeatUntilSignatureChanges",
]);

const forbiddenKeyFragments = [
  "screenshot",
  "transcript",
  "prompt",
  "modelResponse",
  "visibleText",
  "ocrText",
  "rawOCR",
  "rawAX",
  "axTitle",
  "axValue",
  "axLabel",
  "domText",
  "ariaLabel",
  "point.label",
  "missionAlignment",
  "nearestText",
  "evidence",
  "targetElementId",
  "email",
  "token",
  "credential",
  "payment",
  "customer",
];

const forbiddenFragmentKeyAllowlist = new Set([
  "screenshotCaptureLatencyMs",
  "targetElementIdHash",
]);

const forbiddenValuePatterns = [
  ["email_value", /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
  ["bearer_token_value", /\bbearer\s+[a-z0-9._~+/=-]{12,}\b/i],
  ["secret_key_value", /\b(?:sk|rk|whsec|resend)_(?:live|test)?_?[a-z0-9_]{12,}\b/i],
  ["token_query_value", /\b(?:token|session|magic_link)=\S{8,}/i],
  ["jwt_value", /\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+\b/i],
  ["data_image_value", /data:image\/[a-z0-9.+-]+;base64,/i],
];

export { allowedEventNames, allowedKeys, forbiddenValuePatterns };

export function assertPrivacySafe(event) {
  if (!allowedEventNames.has(event.name)) {
    throw new Error(`Unexpected telemetry event: ${event.name}`);
  }

  for (const [key, value] of Object.entries(event.fields)) {
    if (!allowedKeys.has(key)) {
      throw new Error(`Unexpected telemetry key: ${key}`);
    }
    if (forbiddenFragmentKeyAllowlist.has(key)) {
      for (const [name, pattern] of forbiddenValuePatterns) {
        if (pattern.test(String(value))) {
          throw new Error(`Forbidden telemetry value for ${key}: ${name}`);
        }
      }
      continue;
    }
    for (const fragment of forbiddenKeyFragments) {
      if (key.toLowerCase().includes(fragment.toLowerCase())) {
        throw new Error(`Forbidden telemetry key: ${key}`);
      }
    }
    for (const [name, pattern] of forbiddenValuePatterns) {
      if (pattern.test(String(value))) {
        throw new Error(`Forbidden telemetry value for ${key}: ${name}`);
      }
    }
  }
}
