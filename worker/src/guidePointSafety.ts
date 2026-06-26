import type {
  GuidePoint,
  GuideSceneGraphElement,
  GuideSemanticGrounding,
  GuideSemanticTarget,
  GuideTargetRegion,
  SpiderScreenshot,
} from "./guideTypes";
import { MIN_GUIDE_TARGET_REGION_PIXELS } from "./guideLimits";
import {
  GUIDE_DOT_ACTION_RISKS,
  GUIDE_POINT_AFFORDANCES,
  GUIDE_STALE_TARGET_STABILITIES,
  GUIDE_VISIBLE_MODAL_CONTAINERS,
  SENSITIVE_GUIDE_EVIDENCE_PATTERN,
  UNSAFE_POINT_LABEL_PATTERN,
} from "./guideResponseContract";
import {
  invalidGuideResponse,
  normalizedGuideText,
} from "./guideResponseParsing";

export interface GuidePointValidationContext {
  screenId?: string;
  stageId?: string;
  screenChanged: boolean;
  previousSemanticSignature: string | null;
  screenshots: SpiderScreenshot[];
}

export function assertGuidePointIsSafe(point: GuidePoint, screenConfidence: string): void {
  if (screenConfidence !== "high") {
    invalidGuideResponse();
  }

  const label = point.label?.trim();
  if (!label || UNSAFE_POINT_LABEL_PATTERN.test(label)) {
    invalidGuideResponse();
  }
  const missionAlignment = point.missionAlignment?.trim();
  if (!missionAlignment || UNSAFE_POINT_LABEL_PATTERN.test(missionAlignment)) {
    invalidGuideResponse();
  }
}

export function assertGuidePointIsGrounded(
  point: GuidePoint,
  semanticGrounding: GuideSemanticGrounding,
  validationContext: GuidePointValidationContext
): void {
  const screenshot = screenshotForGuidePoint(point, validationContext.screenshots);
  const safeTargets = semanticGrounding.interactiveTargets.filter((target) => (
    guideTargetCanOwnPoint(target, point, semanticGrounding, validationContext, screenshot)
  ));

  if (safeTargets.length === 0) {
    invalidGuideResponse();
  }

  if (semanticGrounding.blockedTargets.some((target) => (
    target.region !== null && pointIsInsideRegion(point, target.region)
  ))) {
    invalidGuideResponse();
  }

  const relatedTarget = safeTargets.find((target) => guideTargetMatchesPointLabel(target, point));
  if (!relatedTarget) {
    invalidGuideResponse();
  }

  if (modalContextIsVisible(semanticGrounding) && !GUIDE_VISIBLE_MODAL_CONTAINERS.has(relatedTarget.container)) {
    if (!targetEvidenceAllowsOutsideModalContext(relatedTarget)) {
      invalidGuideResponse();
    }
  }
}

function guideTargetCanOwnPoint(
  target: GuideSemanticTarget,
  point: GuidePoint,
  semanticGrounding: GuideSemanticGrounding,
  validationContext: GuidePointValidationContext,
  screenshot: SpiderScreenshot | null
): boolean {
  if (
    target.risk !== "low"
    || target.region === null
    || target.targetConfidence !== "high"
    || !GUIDE_POINT_AFFORDANCES.has(target.affordance)
    || target.state === "disabled"
    || target.state === "loading"
  ) {
    return false;
  }
  if (GUIDE_STALE_TARGET_STABILITIES.has(target.targetStability)) {
    return false;
  }
  if (validationContext.screenChanged && target.targetStability === "unknown") {
    return false;
  }
  if (
    validationContext.previousSemanticSignature
    && validationContext.previousSemanticSignature !== semanticGrounding.semanticSignature
    && target.targetStability === "unknown"
  ) {
    return false;
  }
  const actionRisk = guideActionRiskForTarget(target, point, validationContext);
  if (!GUIDE_DOT_ACTION_RISKS.has(actionRisk)) {
    return false;
  }
  if (!guideTargetTextIsSafe(target)) {
    return false;
  }
  if (!isPlausibleGuideTargetRegion(target.region, screenshot)) {
    return false;
  }
  if (!guideTargetElementIsValid(target, semanticGrounding, screenshot)) {
    return false;
  }
  if (point.targetElementId !== null && point.targetElementId !== target.elementId) {
    return false;
  }
  return pointIsInsideRegion(point, target.region);
}

function guideActionRiskForTarget(
  target: GuideSemanticTarget,
  point: GuidePoint,
  validationContext: GuidePointValidationContext
): string {
  const normalizedContext = [
    validationContext.screenId,
    validationContext.stageId,
    point.expectedOutcome,
    target.role,
    target.container,
    target.state,
    target.risk,
    target.semanticIntent,
    target.label,
    target.affordance,
  ].filter(Boolean).join(" ").toLowerCase();

  if (/\b(billing|payment|card|bank|tax|invoice|pay|checkout)\b/.test(normalizedContext)) {
    return "billing_boundary";
  }
  if (/\b(2fa|two-factor|two factor|verification code|security code|password|credential|login|auth|recovery)\b/.test(normalizedContext)) {
    return "auth_boundary";
  }
  if (/\b(publish|launch|submit|go live|send campaign|place order)\b/.test(normalizedContext)) {
    return "publish_boundary";
  }
  if (/\b(budget|spend|bid|spending limit|increase budget|daily budget)\b/.test(normalizedContext)) {
    return "spend_boundary";
  }
  if (/\b(policy|appeal|account quality|business verification|domain verification)\b/.test(normalizedContext)) {
    return "policy_boundary";
  }
  if (/\b(delete|remove|discard|deactivate|pause|irreversible|destructive)\b/.test(normalizedContext)) {
    return "destructive";
  }
  if (target.risk !== "low") {
    return "unknown";
  }

  if (point.expectedOutcome === "tile_selected" || point.expectedOutcome === "item_selected") {
    return "selection";
  }
  if (point.expectedOutcome === "field_focused" || point.expectedOutcome === "field_filled") {
    return "input";
  }
  if (point.expectedOutcome === "screen_advanced" || point.expectedOutcome === "wizard_advanced" || point.expectedOutcome === "stage_advanced") {
    return "navigation";
  }
  if (target.affordance === "select") {
    return "selection";
  }
  if (target.affordance === "type") {
    return "input";
  }
  if (target.affordance === "click") {
    return "reversible";
  }
  if (target.affordance === "read") {
    return "read_only";
  }
  if (target.affordance === "wait") {
    return "wait";
  }
  return "unknown";
}

function guideTargetElementIsValid(
  target: GuideSemanticTarget,
  semanticGrounding: GuideSemanticGrounding,
  screenshot: SpiderScreenshot | null
): boolean {
  if (target.elementId === null) {
    return true;
  }
  const element = semanticGrounding.elements.find((candidate) => candidate.id === target.elementId);
  if (!element || element.occluded || element.confidence !== "high") {
    return false;
  }
  if (!guideSceneGraphElementTextIsSafe(element)) {
    return false;
  }
  if (element.region === null || target.region === null) {
    return false;
  }
  if (!isPlausibleGuideTargetRegion(element.region, screenshot)) {
    return false;
  }
  return regionsAreCompatible(target.region, element.region);
}

function guideSceneGraphElementTextIsSafe(element: GuideSceneGraphElement): boolean {
  const elementText = [
    element.id,
    element.label,
    element.role,
    element.containerId || "",
    element.parentId || "",
    ...element.evidence,
  ].join(" ");
  return !SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(elementText);
}

function regionsAreCompatible(first: GuideTargetRegion, second: GuideTargetRegion): boolean {
  const overlapWidth = Math.max(
    0,
    Math.min(first.x + first.width, second.x + second.width) - Math.max(first.x, second.x)
  );
  const overlapHeight = Math.max(
    0,
    Math.min(first.y + first.height, second.y + second.height) - Math.max(first.y, second.y)
  );
  const overlapArea = overlapWidth * overlapHeight;
  const smallerArea = Math.min(first.width * first.height, second.width * second.height);
  return smallerArea > 0 && overlapArea / smallerArea >= 0.6;
}

function guideTargetTextIsSafe(target: GuideSemanticTarget): boolean {
  const targetText = [
    target.label,
    target.parentLabel || "",
    ...target.nearestText,
    target.semanticIntent,
    ...target.evidence,
  ].join(" ");
  return !UNSAFE_POINT_LABEL_PATTERN.test(targetText)
    && !SENSITIVE_GUIDE_EVIDENCE_PATTERN.test(targetText);
}

function guideTargetMatchesPointLabel(target: GuideSemanticTarget, point: GuidePoint): boolean {
  if (!point.label) {
    return false;
  }
  const normalizedPointLabel = normalizedGuideText(point.label);
  const relatedText = [
    target.label,
    target.semanticIntent,
    target.parentLabel || "",
    ...target.nearestText,
    ...target.evidence,
  ].map(normalizedGuideText).join(" ");

  return relatedText.includes(normalizedPointLabel)
    || normalizedPointLabel.includes(normalizedGuideText(target.label));
}

function pointIsInsideRegion(point: GuidePoint, region: GuideTargetRegion): boolean {
  return point.x >= region.x
    && point.y >= region.y
    && point.x <= region.x + region.width
    && point.y <= region.y + region.height;
}

function isPlausibleGuideTargetRegion(region: GuideTargetRegion, screenshot: SpiderScreenshot | null): boolean {
  if (region.width < MIN_GUIDE_TARGET_REGION_PIXELS || region.height < MIN_GUIDE_TARGET_REGION_PIXELS) {
    return false;
  }
  if (!screenshot) {
    return true;
  }
  if (
    region.x + region.width > screenshot.screenshotWidthInPixels
    || region.y + region.height > screenshot.screenshotHeightInPixels
  ) {
    return false;
  }

  const screenshotArea = screenshot.screenshotWidthInPixels * screenshot.screenshotHeightInPixels;
  const regionArea = region.width * region.height;
  return regionArea <= screenshotArea * 0.9;
}

function screenshotForGuidePoint(point: GuidePoint, screenshots: SpiderScreenshot[]): SpiderScreenshot | null {
  if (point.screenNumber !== null) {
    return screenshots[point.screenNumber - 1] || null;
  }
  return screenshots.length === 1 ? screenshots[0] : null;
}

function modalContextIsVisible(semanticGrounding: GuideSemanticGrounding): boolean {
  return [...semanticGrounding.interactiveTargets, ...semanticGrounding.blockedTargets]
    .some((target) => GUIDE_VISIBLE_MODAL_CONTAINERS.has(target.container));
}

function targetEvidenceAllowsOutsideModalContext(target: GuideSemanticTarget): boolean {
  const evidenceText = [
    target.label,
    target.semanticIntent,
    ...target.evidence,
  ].join(" ");
  return /\boutside (the )?(modal|dialog|popover)\b/i.test(evidenceText)
    || /\bnot (in|inside) (the )?(modal|dialog|popover)\b/i.test(evidenceText);
}
