import { parseJSONText } from "./payloadSecurity";
import { asRecord } from "./structuredValues";
import {
  guideSemanticGrounding,
  withDerivedSemanticSignature,
} from "./guideSemanticGrounding";
import { guidePointOrNull } from "./guidePointParsing";
import { assertGuideScreenSafety } from "./guideScreenSafety";
import {
  boundedGuideString,
  invalidGuideResponse,
  optionalBoundedGuideString,
} from "./guideResponseParsing";
import {
  guideAdMissionUpdateOrNull,
  guideArtifactOrNull,
} from "./guideResponseExtras";
import type { GuideValidationContext } from "./guideValidationContext";
import {
  MAX_AD_MISSION_LIST_ITEM_CHARS,
  MAX_GUIDE_CONTEXT_KIND_CHARS,
  MAX_GUIDE_DISPLAY_TEXT_CHARS,
  MAX_GUIDE_DISPLAY_WORDS,
  MAX_GUIDE_NEXT_STEP_CHARS,
  MAX_GUIDE_OUTPUT_TEXT_CHARS,
  MAX_GUIDE_POLL_AFTER_MS,
  MAX_GUIDE_SCREEN_EVIDENCE_CHARS,
  MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
  MAX_GUIDE_SCREEN_IDENTIFIER_CHARS,
  MAX_GUIDE_SPOKEN_SENTENCES,
  MAX_GUIDE_SPOKEN_TEXT_CHARS,
} from "./guideLimits";
import {
  GUIDE_CONFIDENCE_LEVELS,
  GUIDE_CONTEXT_KINDS,
  GUIDE_DECISIONS,
  GUIDE_RISK_LEVELS,
  GUIDE_SCREEN_STATES,
  GUIDE_SOURCE_TYPES,
  SENSITIVE_GUIDE_EVIDENCE_PATTERN,
} from "./guideResponseContract";

export function guideResponsePayload(
  responseText: string,
  validationContext: GuideValidationContext
): Record<string, unknown> {
  if (responseText.length > MAX_GUIDE_OUTPUT_TEXT_CHARS) {
    invalidGuideResponse();
  }

  const parsed = parseJSONText(responseText, "OpenAI returned an invalid guide response.", 502);
  const guide = asRecord(parsed);
  requireGuideFields(guide, [
    "spokenText",
    "displayText",
    "nextStep",
    "semanticGrounding",
    "screenState",
    "screenId",
    "stageId",
    "screenConfidence",
    "screenEvidence",
    "shouldContinuePolling",
    "pollAfterMs",
    "contextKind",
    "officialRule",
    "spiderJudgment",
    "decision",
    "riskLevel",
    "confidence",
    "sourceType",
    "requiresManualConfirmation",
    "reviewTrigger",
    "decisionMemoryUpdate",
    "point",
    "adMissionUpdate",
    "artifact",
  ]);
  const spokenText = boundedGuideString(guide.spokenText, MAX_GUIDE_SPOKEN_TEXT_CHARS);
  const displayText = boundedGuideString(guide.displayText, MAX_GUIDE_DISPLAY_TEXT_CHARS, true);
  const nextStep = boundedGuideString(guide.nextStep, MAX_GUIDE_NEXT_STEP_CHARS, true);
  const screenState = boundedGuideString(guide.screenState, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const screenId = boundedGuideString(guide.screenId, MAX_GUIDE_SCREEN_IDENTIFIER_CHARS, true);
  const stageId = boundedGuideString(guide.stageId, MAX_GUIDE_SCREEN_IDENTIFIER_CHARS, true);
  const semanticGrounding = withDerivedSemanticSignature(
    guideSemanticGrounding(guide.semanticGrounding),
    screenId,
    stageId
  );
  const screenConfidence = boundedGuideString(guide.screenConfidence, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const screenEvidence = guideScreenEvidence(guide.screenEvidence);
  const contextKind = boundedGuideString(guide.contextKind, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const officialRule = optionalBoundedGuideString(guide.officialRule, MAX_GUIDE_DISPLAY_TEXT_CHARS);
  const spiderJudgment = boundedGuideString(guide.spiderJudgment, MAX_GUIDE_DISPLAY_TEXT_CHARS, true);
  const decision = boundedGuideString(guide.decision, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const riskLevel = boundedGuideString(guide.riskLevel, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const confidence = boundedGuideString(guide.confidence, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const sourceType = boundedGuideString(guide.sourceType, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  const reviewTrigger = optionalBoundedGuideString(guide.reviewTrigger, MAX_GUIDE_NEXT_STEP_CHARS);
  const decisionMemoryUpdate = optionalBoundedGuideString(
    guide.decisionMemoryUpdate,
    MAX_AD_MISSION_LIST_ITEM_CHARS
  );

  if (!GUIDE_SCREEN_STATES.has(screenState)) {
    invalidGuideResponse();
  }
  if (!GUIDE_CONFIDENCE_LEVELS.has(screenConfidence)) {
    invalidGuideResponse();
  }
  if (!GUIDE_CONTEXT_KINDS.has(contextKind)) {
    invalidGuideResponse();
  }
  if (!GUIDE_DECISIONS.has(decision)) {
    invalidGuideResponse();
  }
  if (!GUIDE_RISK_LEVELS.has(riskLevel)) {
    invalidGuideResponse();
  }
  if (!GUIDE_CONFIDENCE_LEVELS.has(confidence)) {
    invalidGuideResponse();
  }
  if (!GUIDE_SOURCE_TYPES.has(sourceType)) {
    invalidGuideResponse();
  }
  if (typeof guide.requiresManualConfirmation !== "boolean") {
    invalidGuideResponse();
  }
  if (typeof guide.shouldContinuePolling !== "boolean") {
    invalidGuideResponse();
  }
  assertGuideDialogueBounds(displayText, spokenText);
  assertManualConfirmationBoundary(decision, guide.requiresManualConfirmation);
  const point = guidePointOrNull(guide.point);
  assertGuideScreenSafety({
    screenState,
    screenId,
    stageId,
    screenConfidence,
    requiresManualConfirmation: guide.requiresManualConfirmation,
    semanticGrounding,
    point,
    validationContext,
  });
  const pollAfterMs = guidePollAfterMsOrNull(guide.pollAfterMs);

  return {
    spokenText,
    displayText,
    nextStep,
    semanticGrounding,
    screenState,
    screenId,
    stageId,
    screenConfidence,
    screenEvidence,
    shouldContinuePolling: guide.shouldContinuePolling,
    pollAfterMs,
    contextKind,
    officialRule,
    spiderJudgment,
    decision,
    riskLevel,
    confidence,
    sourceType,
    requiresManualConfirmation: guide.requiresManualConfirmation,
    reviewTrigger,
    decisionMemoryUpdate,
    point,
    adMissionUpdate: guideAdMissionUpdateOrNull(guide.adMissionUpdate),
    artifact: guideArtifactOrNull(guide.artifact),
  };
}

function requireGuideFields(guide: Record<string, unknown>, fieldNames: string[]): void {
  for (const fieldName of fieldNames) {
    if (!(fieldName in guide)) {
      invalidGuideResponse();
    }
  }
}

function assertManualConfirmationBoundary(decision: string, requiresManualConfirmation: boolean): void {
  if ((decision === "manual_confirmation_required" || decision === "do_not_publish") && !requiresManualConfirmation) {
    invalidGuideResponse();
  }
}

function assertGuideDialogueBounds(displayText: string, spokenText: string): void {
  if (displayText.includes("\n") || wordCount(displayText) > MAX_GUIDE_DISPLAY_WORDS) {
    invalidGuideResponse();
  }
  if (spokenText.includes("\n") || sentenceCount(spokenText) > MAX_GUIDE_SPOKEN_SENTENCES) {
    invalidGuideResponse();
  }
}

function wordCount(value: string): number {
  return value.trim().split(/\s+/).filter(Boolean).length;
}

function sentenceCount(value: string): number {
  const trimmedValue = value.trim();
  if (!trimmedValue) {
    return 0;
  }
  const sentences = trimmedValue
    .split(/[.!?]+/)
    .map((sentence) => sentence.trim())
    .filter(Boolean);
  return Math.max(1, sentences.length);
}

function guideScreenEvidence(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > MAX_GUIDE_SCREEN_EVIDENCE_ITEMS) {
    invalidGuideResponse();
  }

  return value.map((item) => {
    const evidence = boundedGuideString(item, MAX_GUIDE_SCREEN_EVIDENCE_CHARS, true);
    if (SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(evidence)) {
      invalidGuideResponse();
    }
    return evidence;
  });
}

function guidePollAfterMsOrNull(value: unknown): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (
    typeof value !== "number"
    || !Number.isInteger(value)
    || value < 1_000
    || value > MAX_GUIDE_POLL_AFTER_MS
  ) {
    invalidGuideResponse();
  }
  return value;
}
