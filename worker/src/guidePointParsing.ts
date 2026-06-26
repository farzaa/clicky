import { asRecord } from "./structuredValues";
import {
  MAX_GUIDE_CONTEXT_KIND_CHARS,
  MAX_GUIDE_POINT_LABEL_CHARS,
  MAX_GUIDE_POINT_MISSION_ALIGNMENT_CHARS,
  MAX_GUIDE_POINT_SCREEN_NUMBER,
  MAX_SCREENSHOT_DIMENSION_PIXELS,
} from "./guideLimits";
import {
  GUIDE_POINT_EXPECTED_OUTCOMES,
  SENSITIVE_GUIDE_EVIDENCE_PATTERN,
} from "./guideResponseContract";
import { invalidGuideResponse } from "./guideResponseParsing";
import type { GuidePoint } from "./guideTypes";

export function guidePointOrNull(value: unknown): GuidePoint | null {
  if (value === null || value === undefined) {
    return null;
  }

  const point = asRecord(value);
  const x = point.x;
  const y = point.y;
  const label = point.label;
  const screenNumber = point.screenNumber;
  const missionAlignment = point.missionAlignment;
  const targetElementId = point.targetElementId;
  const expectedOutcome = point.expectedOutcome;

  if (
    typeof x !== "number"
    || typeof y !== "number"
    || !Number.isFinite(x)
    || !Number.isFinite(y)
    || x < 0
    || y < 0
    || x > MAX_SCREENSHOT_DIMENSION_PIXELS
    || y > MAX_SCREENSHOT_DIMENSION_PIXELS
  ) {
    return null;
  }

  if (
    screenNumber !== null
    && screenNumber !== undefined
    && (
      typeof screenNumber !== "number"
      || !Number.isInteger(screenNumber)
      || screenNumber < 1
      || screenNumber > MAX_GUIDE_POINT_SCREEN_NUMBER
    )
  ) {
    return null;
  }

  if (label !== null && label !== undefined) {
    if (typeof label !== "string" || label.includes("\u0000") || label.length > MAX_GUIDE_POINT_LABEL_CHARS) {
      return null;
    }
  }
  if (missionAlignment !== null && missionAlignment !== undefined) {
    if (typeof missionAlignment === "string" && SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(missionAlignment)) {
      invalidGuideResponse();
    }
    if (
      typeof missionAlignment !== "string"
      || missionAlignment.includes("\u0000")
      || missionAlignment.length > MAX_GUIDE_POINT_MISSION_ALIGNMENT_CHARS
    ) {
      return null;
    }
  }
  if (targetElementId !== null && targetElementId !== undefined) {
    if (
      typeof targetElementId !== "string"
      || targetElementId.includes("\u0000")
      || /\s/.test(targetElementId)
      || targetElementId.length > MAX_GUIDE_CONTEXT_KIND_CHARS
      || SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(targetElementId)
    ) {
      return null;
    }
  }
  if (typeof expectedOutcome !== "string" || !GUIDE_POINT_EXPECTED_OUTCOMES.has(expectedOutcome)) {
    return null;
  }

  return {
    x,
    y,
    label: label ?? null,
    screenNumber: screenNumber ?? null,
    missionAlignment: missionAlignment ?? null,
    targetElementId: targetElementId ?? null,
    expectedOutcome,
  };
}
