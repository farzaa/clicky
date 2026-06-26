import { asRecord, stringOrNull } from "./structuredValues";
import type {
  SpiderScreenshot,
  SpiderVisionGuideRequest,
} from "./guideTypes";
import { GUIDE_POINT_EXPECTED_OUTCOMES } from "./guideResponseContract";

export interface GuideValidationContext {
  screenId?: string;
  stageId?: string;
  screenChanged: boolean;
  previousSemanticSignature: string | null;
  pendingPointOutcome: {
    targetElementIdHash: string | null;
    targetFingerprint: string | null;
    targetFingerprintCompatibility: string | null;
    screenId: string | null;
    stageId: string | null;
    semanticSignature: string | null;
    groundingRevision: string | null;
    expectedOutcome: string | null;
    retryAllowed: boolean | null;
    retryReason: string | null;
    requiresUserConfirmationAfterFailure: boolean | null;
    doNotRepeatUntilSignatureChanges: boolean | null;
  } | null;
  screenshots: SpiderScreenshot[];
}

export function guideValidationContextForRequest(body: SpiderVisionGuideRequest): GuideValidationContext {
  const guidedSessionContext = asRecord(body.guidedSessionContext);
  const explicitScreenChanged = guidedSessionContext.screenChanged;
  return {
    screenChanged: typeof explicitScreenChanged === "boolean"
      ? explicitScreenChanged
      : /\bscreenChanged\s*=\s*true\b/i.test(body.userTranscript),
    previousSemanticSignature: stringOrNull(guidedSessionContext.previousSemanticSignature),
    pendingPointOutcome: guidePendingPointOutcomeOrNull(guidedSessionContext.pendingPointOutcome),
    screenshots: body.screenshots,
  };
}

function guidePendingPointOutcomeOrNull(value: unknown): GuideValidationContext["pendingPointOutcome"] {
  if (value === undefined || value === null) {
    return null;
  }
  const outcome = asRecord(value);
  if (Object.keys(outcome).length === 0) {
    return null;
  }
  const expectedOutcome = stringOrNull(outcome.expectedOutcome);
  return {
    targetElementIdHash: stringOrNull(outcome.targetElementIdHash),
    targetFingerprint: stringOrNull(outcome.targetFingerprint),
    targetFingerprintCompatibility: stringOrNull(outcome.targetFingerprintCompatibility),
    screenId: stringOrNull(outcome.screenId),
    stageId: stringOrNull(outcome.stageId),
    semanticSignature: stringOrNull(outcome.semanticSignature),
    groundingRevision: stringOrNull(outcome.groundingRevision),
    expectedOutcome: expectedOutcome && GUIDE_POINT_EXPECTED_OUTCOMES.has(expectedOutcome)
      ? expectedOutcome
      : null,
    retryAllowed: typeof outcome.retryAllowed === "boolean" ? outcome.retryAllowed : null,
    retryReason: stringOrNull(outcome.retryReason),
    requiresUserConfirmationAfterFailure: typeof outcome.requiresUserConfirmationAfterFailure === "boolean"
      ? outcome.requiresUserConfirmationAfterFailure
      : null,
    doNotRepeatUntilSignatureChanges: typeof outcome.doNotRepeatUntilSignatureChanges === "boolean"
      ? outcome.doNotRepeatUntilSignatureChanges
      : null,
  };
}
