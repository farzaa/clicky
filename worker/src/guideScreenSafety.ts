import {
  assertGuidePointIsGrounded,
  assertGuidePointIsSafe,
  type GuidePointValidationContext,
} from "./guidePointSafety";
import {
  GUIDE_LOADING_SCREEN_ID,
  GUIDE_LOADING_STAGE_ID,
  GUIDE_UNKNOWN_SCREEN_ID,
  GUIDE_UNKNOWN_STAGE_ID,
  POINT_RESTRICTED_SCREEN_IDS,
  POINT_RESTRICTED_STAGE_IDS,
} from "./guideResponseContract";
import { invalidGuideResponse } from "./guideResponseParsing";
import type {
  GuidePoint,
  GuideSemanticGrounding,
} from "./guideTypes";

export interface GuideScreenSafetyInput {
  screenState: string;
  screenId: string;
  stageId: string;
  screenConfidence: string;
  requiresManualConfirmation: boolean;
  semanticGrounding: GuideSemanticGrounding;
  point: GuidePoint | null;
  validationContext: GuidePointValidationContext;
}

export function assertGuideScreenSafety(input: GuideScreenSafetyInput): void {
  if (input.screenState === "loading") {
    if (
      input.screenId !== GUIDE_LOADING_SCREEN_ID
      || input.stageId !== GUIDE_LOADING_STAGE_ID
      || input.point !== null
    ) {
      invalidGuideResponse();
    }
    return;
  }

  if (input.screenState === "unknown") {
    if (
      input.screenId !== GUIDE_UNKNOWN_SCREEN_ID
      || input.stageId !== GUIDE_UNKNOWN_STAGE_ID
      || !input.requiresManualConfirmation
      || input.point !== null
    ) {
      invalidGuideResponse();
    }
    return;
  }

  const isRestrictedBoundary = guideScreenOrStageRestrictsPoint(input.screenId, input.stageId);

  if (input.screenState === "blocked") {
    if (!input.requiresManualConfirmation || input.point !== null) {
      invalidGuideResponse();
    }
    return;
  }

  if (isRestrictedBoundary) {
    invalidGuideResponse();
  }

  if (input.point !== null) {
    assertGuidePointIsSafe(input.point, input.screenConfidence);
    assertGuidePointIsGrounded(input.point, input.semanticGrounding, {
      ...input.validationContext,
      screenId: input.screenId,
      stageId: input.stageId,
    });
  }
}

function guideScreenOrStageRestrictsPoint(screenId: string, stageId: string): boolean {
  return POINT_RESTRICTED_SCREEN_IDS.has(screenId) || POINT_RESTRICTED_STAGE_IDS.has(stageId);
}
