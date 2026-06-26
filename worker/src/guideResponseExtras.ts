import {
  MAX_AD_MISSION_LIST_ITEM_CHARS,
  MAX_AD_MISSION_LIST_ITEMS,
  MAX_AD_MISSION_TEXT_FIELD_CHARS,
  MAX_ARTIFACT_MARKDOWN_CHARS,
  MAX_ARTIFACT_TITLE_CHARS,
  MAX_GUIDE_CONTEXT_KIND_CHARS,
} from "./guideLimits";
import { GUIDE_ARTIFACT_KINDS } from "./guideResponseContract";
import {
  boundedGuideString,
  invalidGuideResponse,
  optionalBoundedGuideString,
} from "./guideResponseParsing";

export function guideArtifactOrNull(value: unknown): Record<string, unknown> | null {
  if (value === null || value === undefined) {
    return null;
  }

  const artifact = guideRecord(value);
  const kind = boundedGuideString(artifact.kind, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  if (!GUIDE_ARTIFACT_KINDS.has(kind)) {
    invalidGuideResponse();
  }

  return {
    kind,
    title: boundedGuideString(artifact.title, MAX_ARTIFACT_TITLE_CHARS, true),
    markdown: boundedGuideString(artifact.markdown, MAX_ARTIFACT_MARKDOWN_CHARS, true),
  };
}

export function guideAdMissionUpdateOrNull(value: unknown): Record<string, unknown> | null {
  if (value === null || value === undefined) {
    return null;
  }

  const adMissionUpdate = guideRecord(value);
  return {
    offer: optionalBoundedGuideString(adMissionUpdate.offer, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    targetAudience: optionalBoundedGuideString(adMissionUpdate.targetAudience, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    ticket: optionalBoundedGuideString(adMissionUpdate.ticket, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    country: optionalBoundedGuideString(adMissionUpdate.country, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    language: optionalBoundedGuideString(adMissionUpdate.language, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    budget: optionalBoundedGuideString(adMissionUpdate.budget, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    businessObjective: optionalBoundedGuideString(adMissionUpdate.businessObjective, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    landingPageURL: optionalBoundedGuideString(adMissionUpdate.landingPageURL, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    recommendedChannel: optionalBoundedGuideString(adMissionUpdate.recommendedChannel, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    campaignPlan: optionalBoundedGuideString(adMissionUpdate.campaignPlan, MAX_AD_MISSION_TEXT_FIELD_CHARS),
    decisions: optionalBoundedGuideStringArray(adMissionUpdate.decisions),
    reviewSchedule: optionalBoundedGuideString(adMissionUpdate.reviewSchedule, MAX_AD_MISSION_TEXT_FIELD_CHARS),
  };
}

function guideRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    invalidGuideResponse();
  }
  return value as Record<string, unknown>;
}

function optionalBoundedGuideStringArray(value: unknown): string[] | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (!Array.isArray(value) || value.length > MAX_AD_MISSION_LIST_ITEMS) {
    invalidGuideResponse();
  }
  return value.map((item) => boundedGuideString(item, MAX_AD_MISSION_LIST_ITEM_CHARS, true));
}
