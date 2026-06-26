import { HttpError } from "./http";
import {
  ALLOWED_SCREENSHOT_MIME_TYPES,
  MAX_AD_MISSION_SNAPSHOT_CHARS,
  MAX_APP_LANGUAGE_CHARS,
  MAX_GUIDE_CONTEXT_KIND_CHARS,
  MAX_GUIDE_POINT_LABEL_CHARS,
  MAX_GUIDE_POINT_MISSION_ALIGNMENT_CHARS,
  MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
  MAX_HISTORY_TEXT_CHARS,
  MAX_HISTORY_TURNS,
  MAX_PLATFORM_CONTEXT_CHARS,
  MAX_SCREENSHOT_COUNT,
  MAX_SCREENSHOT_DIMENSION_PIXELS,
  MAX_SINGLE_SCREENSHOT_BASE64_CHARS,
  MAX_USER_TRANSCRIPT_CHARS,
} from "./guideLimits";
import type { SpiderVisionGuideRequest } from "./guideTypes";
import { MAX_DEVICE_IDENTIFIER_CHARS } from "./identitySecurity";
import { asRecord, stringOrNull } from "./structuredValues";
import {
  assertOptionalStringLimit,
  assertPositiveBoundedNumber,
  isValidBase64,
} from "./validationPrimitives";

export interface GuideRequestValidationPolicy {
  expectedOutcomes: ReadonlySet<string>;
  sensitiveEvidencePattern: RegExp;
  unsafePointLabelPattern: RegExp;
}

export function validateVisionGuideRequest(
  body: SpiderVisionGuideRequest,
  policy: GuideRequestValidationPolicy
): void {
  if (typeof body.userTranscript !== "string" || !body.userTranscript.trim()) {
    throw new HttpError(400, "Missing user transcript.");
  }
  if (body.userTranscript.length > MAX_USER_TRANSCRIPT_CHARS) {
    throw new HttpError(413, "User transcript is too large.");
  }
  assertOptionalStringLimit(body.appLanguage, "App language", MAX_APP_LANGUAGE_CHARS);
  validateGuidedSessionContext(body.guidedSessionContext, policy);

  if (!Array.isArray(body.screenshots) || body.screenshots.length === 0) {
    throw new HttpError(400, "Spider needs at least one screenshot.");
  }
  if (body.screenshots.length > MAX_SCREENSHOT_COUNT) {
    throw new HttpError(413, "Too many screenshots.");
  }

  body.screenshots.forEach((screenshotValue, index) => {
    const screenshot = asRecord(screenshotValue);
    const imageBase64 = stringOrNull(screenshot.imageBase64);
    const mimeType = stringOrNull(screenshot.mimeType)?.toLowerCase() || "";

    if (!ALLOWED_SCREENSHOT_MIME_TYPES.has(mimeType)) {
      throw new HttpError(400, `Screenshot ${index + 1} has an unsupported image type.`);
    }
    if (!imageBase64) {
      throw new HttpError(400, `Screenshot ${index + 1} is missing image data.`);
    }
    if (imageBase64.length > MAX_SINGLE_SCREENSHOT_BASE64_CHARS) {
      throw new HttpError(413, `Screenshot ${index + 1} is too large.`);
    }
    if (!isValidBase64(imageBase64)) {
      throw new HttpError(400, `Screenshot ${index + 1} has invalid image data.`);
    }

    assertPositiveBoundedNumber(
      screenshot.screenshotWidthInPixels,
      `Screenshot ${index + 1} width`,
      MAX_SCREENSHOT_DIMENSION_PIXELS
    );
    assertPositiveBoundedNumber(
      screenshot.screenshotHeightInPixels,
      `Screenshot ${index + 1} height`,
      MAX_SCREENSHOT_DIMENSION_PIXELS
    );
    assertPositiveBoundedNumber(
      screenshot.displayWidthInPoints,
      `Screenshot ${index + 1} display width`,
      MAX_SCREENSHOT_DIMENSION_PIXELS
    );
    assertPositiveBoundedNumber(
      screenshot.displayHeightInPoints,
      `Screenshot ${index + 1} display height`,
      MAX_SCREENSHOT_DIMENSION_PIXELS
    );
  });

  if (body.conversationHistory !== undefined) {
    if (!Array.isArray(body.conversationHistory)) {
      throw new HttpError(400, "Conversation history is invalid.");
    }
    if (body.conversationHistory.length > MAX_HISTORY_TURNS) {
      throw new HttpError(413, "Conversation history is too large.");
    }
    for (const turnValue of body.conversationHistory) {
      const turn = asRecord(turnValue);
      assertOptionalStringLimit(
        turn.userTranscript,
        "Conversation user transcript",
        MAX_HISTORY_TEXT_CHARS
      );
      assertOptionalStringLimit(
        turn.assistantResponse,
        "Conversation assistant response",
        MAX_HISTORY_TEXT_CHARS
      );
    }
  }

  if (body.platformContext !== undefined) {
    const platformContext = asRecord(body.platformContext);
    if (Object.keys(platformContext).length === 0) {
      throw new HttpError(400, "Platform context is invalid.");
    }
    const serializedPlatformContext = JSON.stringify(platformContext);
    if (serializedPlatformContext.length > MAX_PLATFORM_CONTEXT_CHARS) {
      throw new HttpError(413, "Platform context is too large.");
    }
    assertOptionalStringLimit(platformContext.candidatePlatformId, "Platform id", MAX_GUIDE_CONTEXT_KIND_CHARS);
    assertOptionalStringLimit(platformContext.source, "Platform context source", MAX_GUIDE_CONTEXT_KIND_CHARS);
    assertOptionalStringLimit(platformContext.visibleURLHost, "Visible URL host", MAX_DEVICE_IDENTIFIER_CHARS);
  }

  if (body.adMissionSnapshot !== undefined) {
    const adMission = asRecord(body.adMissionSnapshot);
    if (Object.keys(adMission).length === 0) {
      throw new HttpError(400, "Ad Mission snapshot is invalid.");
    }
    const serializedAdMission = JSON.stringify(adMission);
    if (serializedAdMission.length > MAX_AD_MISSION_SNAPSHOT_CHARS) {
      throw new HttpError(413, "Ad Mission snapshot is too large.");
    }
  }
}

function validateGuidedSessionContext(
  value: unknown,
  policy: GuideRequestValidationPolicy
): void {
  if (value === undefined || value === null) {
    return;
  }
  const context = asRecord(value);
  if (Object.keys(context).length === 0) {
    throw new HttpError(400, "Guided session context is invalid.");
  }
  assertOptionalGuidedSessionText(
    context.currentScreenSignature,
    "Current screen signature",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS * 4,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    context.previousScreenSignature,
    "Previous screen signature",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS * 4,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    context.previousSemanticSignature,
    "Previous semantic signature",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS * 4,
    false,
    policy
  );
  if (context.screenChanged !== undefined && typeof context.screenChanged !== "boolean") {
    throw new HttpError(400, "Screen changed flag is invalid.");
  }

  validatePendingPointOutcomeContext(context.pendingPointOutcome, policy);

  if (context.previousAcceptedTarget === undefined || context.previousAcceptedTarget === null) {
    return;
  }
  const previousAcceptedTarget = asRecord(context.previousAcceptedTarget);
  if (Object.keys(previousAcceptedTarget).length === 0) {
    throw new HttpError(400, "Previous accepted target is invalid.");
  }
  assertOptionalGuidedSessionText(
    previousAcceptedTarget.label,
    "Previous target label",
    MAX_GUIDE_POINT_LABEL_CHARS,
    true,
    policy
  );
  assertOptionalGuidedSessionText(
    previousAcceptedTarget.missionAlignment,
    "Previous target mission alignment",
    MAX_GUIDE_POINT_MISSION_ALIGNMENT_CHARS,
    true,
    policy
  );
  assertOptionalGuidedSessionText(
    previousAcceptedTarget.screenId,
    "Previous target screen ID",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    previousAcceptedTarget.stageId,
    "Previous target stage ID",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
    false,
    policy
  );
}

function validatePendingPointOutcomeContext(
  value: unknown,
  policy: GuideRequestValidationPolicy
): void {
  if (value === undefined || value === null) {
    return;
  }
  const outcome = asRecord(value);
  if (Object.keys(outcome).length === 0) {
    throw new HttpError(400, "Pending point outcome is invalid.");
  }
  assertOptionalGuidedSessionText(
    outcome.pointLabel,
    "Pending point label",
    MAX_GUIDE_POINT_LABEL_CHARS,
    true,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.targetElementId,
    "Pending point target element ID",
    MAX_GUIDE_CONTEXT_KIND_CHARS,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.targetElementIdHash,
    "Pending point target element hash",
    64,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.targetFingerprint,
    "Pending point target fingerprint",
    64,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.targetFingerprintCompatibility,
    "Pending point target fingerprint compatibility",
    64,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.screenId,
    "Pending point screen ID",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.stageId,
    "Pending point stage ID",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.semanticSignature,
    "Pending point semantic signature",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS * 4,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.groundingRevision,
    "Pending point grounding revision",
    MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
    false,
    policy
  );
  assertOptionalGuidedSessionText(
    outcome.expectedOutcome,
    "Pending point expected outcome",
    MAX_GUIDE_CONTEXT_KIND_CHARS,
    false,
    policy
  );
  if (
    outcome.expectedOutcome !== undefined
    && outcome.expectedOutcome !== null
    && !policy.expectedOutcomes.has(String(outcome.expectedOutcome))
  ) {
    throw new HttpError(400, "Pending point expected outcome is invalid.");
  }
  for (const key of [
    "retryAllowed",
    "requiresUserConfirmationAfterFailure",
    "doNotRepeatUntilSignatureChanges",
  ]) {
    if (outcome[key] !== undefined && outcome[key] !== null && typeof outcome[key] !== "boolean") {
      throw new HttpError(400, `Pending point ${key} flag is invalid.`);
    }
  }
  assertOptionalGuidedSessionText(
    outcome.retryReason,
    "Pending point retry reason",
    MAX_GUIDE_CONTEXT_KIND_CHARS,
    false,
    policy
  );
}

function assertOptionalGuidedSessionText(
  value: unknown,
  label: string,
  maxLength: number,
  rejectUnsafeActionText: boolean,
  policy: GuideRequestValidationPolicy
): void {
  assertOptionalStringLimit(value, label, maxLength);
  if (typeof value !== "string") {
    return;
  }
  if (policy.sensitiveEvidencePattern.test(value)) {
    throw new HttpError(400, `${label} is invalid.`);
  }
  if (rejectUnsafeActionText && policy.unsafePointLabelPattern.test(value)) {
    throw new HttpError(400, `${label} is invalid.`);
  }
}
