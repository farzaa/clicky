import { asRecord } from "./structuredValues";
import type {
  GuideSceneGraphElement,
  GuideSemanticGrounding,
  GuideSemanticTarget,
  GuideTargetRegion,
} from "./guideTypes";
import {
  MAX_GUIDE_CONTEXT_KIND_CHARS,
  MAX_GUIDE_GROUNDING_TARGETS,
  MAX_GUIDE_GROUNDING_TEXT_CHARS,
  MAX_GUIDE_GROUNDING_UNCERTAINTIES,
  MAX_GUIDE_GROUNDING_VISIBLE_CONCEPTS,
  MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
  MAX_SCREENSHOT_DIMENSION_PIXELS,
} from "./guideLimits";
import {
  GUIDE_CONFIDENCE_LEVELS,
  GUIDE_GROUNDING_CONTAINERS,
  GUIDE_GROUNDING_TARGET_AFFORDANCES,
  GUIDE_GROUNDING_TARGET_RISKS,
  GUIDE_GROUNDING_TARGET_ROLES,
  GUIDE_GROUNDING_TARGET_STABILITIES,
  GUIDE_GROUNDING_TARGET_STATES,
  GUIDE_SCENE_GRAPH_Z_INDEX_HINTS,
  SENSITIVE_GUIDE_EVIDENCE_PATTERN,
} from "./guideResponseContract";
import {
  boundedGuideString,
  invalidGuideResponse,
  normalizedGuideText,
} from "./guideResponseParsing";

export function guideSemanticGrounding(value: unknown): GuideSemanticGrounding {
  const grounding = asRecord(value);
  return {
    groundingRevision: guideGroundingText(grounding.groundingRevision),
    semanticSignature: guideGroundingText(grounding.semanticSignature),
    elements: guideSceneGraphElementArray(grounding.elements),
    visibleConcepts: guideGroundingTextArray(
      grounding.visibleConcepts,
      MAX_GUIDE_GROUNDING_VISIBLE_CONCEPTS
    ),
    interactiveTargets: guideGroundingTargetArray(grounding.interactiveTargets),
    blockedTargets: guideGroundingTargetArray(grounding.blockedTargets),
    uncertainty: guideGroundingTextArray(
      grounding.uncertainty,
      MAX_GUIDE_GROUNDING_UNCERTAINTIES
    ),
  };
}

export function withDerivedSemanticSignature(
  grounding: GuideSemanticGrounding,
  screenId: string,
  stageId: string
): GuideSemanticGrounding {
  return {
    ...grounding,
    semanticSignature: semanticSignatureForGrounding(grounding, screenId, stageId),
  };
}

function semanticSignatureForGrounding(
  grounding: GuideSemanticGrounding,
  screenId: string,
  stageId: string
): string {
  const payload = [
    `screen:${normalizedGuideText(screenId)}`,
    `stage:${normalizedGuideText(stageId)}`,
    `containers:${stableSemanticParts([
      ...grounding.interactiveTargets.map((target) => target.container),
      ...grounding.blockedTargets.map((target) => target.container),
    ]).join("|")}`,
    `labels:${stableSemanticParts(grounding.elements.map((element) => element.label)).slice(0, 12).join("|")}`,
    `safe:${stableSemanticParts(
      grounding.interactiveTargets
        .filter((target) => target.risk === "low")
        .map((target) => target.label)
    ).join("|")}`,
    `blocked:${stableSemanticParts(grounding.blockedTargets.map((target) => target.label)).join("|")}`,
  ].join("\n");

  return `semantic:${stableTextHash(payload)}`;
}

function stableSemanticParts(values: string[]): string[] {
  return [...new Set(values.map(normalizedGuideText).filter(Boolean))].sort();
}

function stableTextHash(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

function guideSceneGraphElementArray(value: unknown): GuideSceneGraphElement[] {
  if (!Array.isArray(value) || value.length > MAX_GUIDE_GROUNDING_TARGETS * 3) {
    invalidGuideResponse();
  }

  const seenIds = new Set<string>();
  return value.map((item) => {
    const element = asRecord(item);
    const id = guideGroundingIdentifier(element.id);
    const label = guideGroundingText(element.label);
    const role = boundedGuideString(element.role, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const containerId = guideGroundingIdentifierOrNull(element.containerId);
    const parentId = guideGroundingIdentifierOrNull(element.parentId);
    const zIndexHint = boundedGuideString(element.zIndexHint, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const confidence = boundedGuideString(element.confidence, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const evidence = guideGroundingTextArray(element.evidence, MAX_GUIDE_SCREEN_EVIDENCE_ITEMS);

    if (
      seenIds.has(id)
      || !GUIDE_SCENE_GRAPH_Z_INDEX_HINTS.has(zIndexHint)
      || !GUIDE_CONFIDENCE_LEVELS.has(confidence)
      || typeof element.occluded !== "boolean"
    ) {
      invalidGuideResponse();
    }
    seenIds.add(id);

    return {
      id,
      label,
      role,
      containerId,
      parentId,
      zIndexHint,
      occluded: element.occluded,
      region: guideGroundingRegionOrNull(element.region),
      confidence,
      evidence,
    };
  });
}

function guideGroundingTextArray(value: unknown, maxItems: number): string[] {
  if (!Array.isArray(value) || value.length > maxItems) {
    invalidGuideResponse();
  }

  return value.map((item) => guideGroundingText(item));
}

function guideGroundingTargetArray(value: unknown): GuideSemanticTarget[] {
  if (!Array.isArray(value) || value.length > MAX_GUIDE_GROUNDING_TARGETS) {
    invalidGuideResponse();
  }

  return value.map((item) => {
    const target = asRecord(item);
    const elementId = guideGroundingIdentifierOrNull(target.elementId);
    const label = guideGroundingText(target.label);
    const semanticIntent = guideGroundingText(target.semanticIntent);
    const role = boundedGuideString(target.role, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const container = boundedGuideString(target.container, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const parentLabel = guideGroundingTextOrNull(target.parentLabel);
    const nearestText = guideGroundingTextArray(target.nearestText, MAX_GUIDE_SCREEN_EVIDENCE_ITEMS);
    const state = boundedGuideString(target.state, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const risk = boundedGuideString(target.risk, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const targetConfidence = boundedGuideString(target.targetConfidence, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const evidence = guideGroundingTextArray(target.evidence, MAX_GUIDE_SCREEN_EVIDENCE_ITEMS);
    const affordance = boundedGuideString(target.affordance, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
    const targetStability = boundedGuideString(target.targetStability, MAX_GUIDE_CONTEXT_KIND_CHARS, true);

    if (
      !GUIDE_GROUNDING_TARGET_ROLES.has(role)
      || !GUIDE_GROUNDING_CONTAINERS.has(container)
      || !GUIDE_GROUNDING_TARGET_STATES.has(state)
      || !GUIDE_GROUNDING_TARGET_RISKS.has(risk)
      || !GUIDE_CONFIDENCE_LEVELS.has(targetConfidence)
      || !GUIDE_GROUNDING_TARGET_AFFORDANCES.has(affordance)
      || !GUIDE_GROUNDING_TARGET_STABILITIES.has(targetStability)
    ) {
      invalidGuideResponse();
    }

    return {
      elementId,
      label,
      role,
      container,
      parentLabel,
      nearestText,
      semanticIntent,
      state,
      risk,
      targetConfidence,
      evidence,
      affordance,
      targetStability,
      region: guideGroundingRegionOrNull(target.region),
    };
  });
}

function guideGroundingTextOrNull(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return guideGroundingText(value);
}

function guideGroundingIdentifierOrNull(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return guideGroundingIdentifier(value);
}

function guideGroundingIdentifier(value: unknown): string {
  const text = boundedGuideString(value, MAX_GUIDE_CONTEXT_KIND_CHARS, true);
  if (SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(text) || /[\u0000\s]/.test(text)) {
    invalidGuideResponse();
  }
  return text;
}

function guideGroundingText(value: unknown): string {
  const text = boundedGuideString(value, MAX_GUIDE_GROUNDING_TEXT_CHARS, true);
  if (SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(text)) {
    invalidGuideResponse();
  }
  return text;
}

function guideGroundingRegionOrNull(value: unknown): GuideTargetRegion | null {
  if (value === null || value === undefined) {
    return null;
  }

  const region = asRecord(value);
  const x = guideGroundingRegionNumber(region.x);
  const y = guideGroundingRegionNumber(region.y);
  const width = guideGroundingRegionNumber(region.width);
  const height = guideGroundingRegionNumber(region.height);
  if (width <= 0 || height <= 0) {
    invalidGuideResponse();
  }
  return { x, y, width, height };
}

function guideGroundingRegionNumber(value: unknown): number {
  if (
    typeof value !== "number"
    || !Number.isFinite(value)
    || value < 0
    || value > MAX_SCREENSHOT_DIMENSION_PIXELS
  ) {
    invalidGuideResponse();
  }
  return value;
}
