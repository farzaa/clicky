import type { SpiderPlatformRequestContext } from "./platforms/types";

export interface SpiderScreenshot {
  label: string;
  imageBase64: string;
  mimeType: string;
  isCursorScreen: boolean;
  displayWidthInPoints: number;
  displayHeightInPoints: number;
  screenshotWidthInPixels: number;
  screenshotHeightInPixels: number;
}

export interface GuidePoint {
  x: number;
  y: number;
  label: string | null;
  screenNumber: number | null;
  missionAlignment: string | null;
  targetElementId: string | null;
  expectedOutcome: string;
}

export interface GuideTargetRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface GuideSemanticTarget {
  elementId: string | null;
  label: string;
  role: string;
  container: string;
  parentLabel: string | null;
  nearestText: string[];
  semanticIntent: string;
  state: string;
  risk: string;
  targetConfidence: string;
  evidence: string[];
  affordance: string;
  targetStability: string;
  region: GuideTargetRegion | null;
}

export interface GuideSceneGraphElement {
  id: string;
  label: string;
  role: string;
  containerId: string | null;
  parentId: string | null;
  zIndexHint: string;
  occluded: boolean;
  region: GuideTargetRegion | null;
  confidence: string;
  evidence: string[];
}

export interface GuideSemanticGrounding {
  groundingRevision: string;
  semanticSignature: string;
  elements: GuideSceneGraphElement[];
  visibleConcepts: string[];
  interactiveTargets: GuideSemanticTarget[];
  blockedTargets: GuideSemanticTarget[];
  uncertainty: string[];
}

export type GroundingCorroborationSource =
  | "openai_vision"
  | "local_ocr"
  | "macos_accessibility"
  | "browser_metadata"
  | "cursor_metadata";

export interface GuidePointAuditorDecision {
  pointIsVisuallyInsideTarget: boolean;
  targetLabelMatches: boolean;
  blockedByModal: boolean;
  targetLooksClickable: boolean;
  shouldAcceptPoint: boolean;
  reason: string;
}

export interface SpiderGuidedSessionContext {
  currentScreenSignature?: string;
  previousScreenSignature?: string | null;
  previousSemanticSignature?: string | null;
  screenChanged?: boolean;
  pendingPointOutcome?: {
    targetElementIdHash?: string | null;
    targetFingerprint?: string | null;
    targetFingerprintCompatibility?: string | null;
    screenId?: string | null;
    stageId?: string | null;
    semanticSignature?: string | null;
    groundingRevision?: string | null;
    expectedOutcome?: string | null;
    retryAllowed?: boolean | null;
    retryReason?: string | null;
    requiresUserConfirmationAfterFailure?: boolean | null;
    doNotRepeatUntilSignatureChanges?: boolean | null;
  } | null;
  previousAcceptedTarget?: {
    label?: string | null;
    missionAlignment?: string | null;
    screenId?: string | null;
    stageId?: string | null;
  } | null;
}

export interface SpiderVisionGuideRequest {
  userTranscript: string;
  appLanguage?: string;
  screenshots: SpiderScreenshot[];
  platformContext?: SpiderPlatformRequestContext;
  guidedSessionContext?: SpiderGuidedSessionContext;
  conversationHistory?: Array<{
    userTranscript: string;
    assistantResponse: string;
  }>;
  adMissionSnapshot?: {
    status?: string;
    offer?: string;
    targetAudience?: string;
    ticket?: string;
    country?: string;
    language?: string;
    budget?: string;
    businessObjective?: string;
    landingPageURL?: string;
    experienceLevel?: string;
    recommendedChannel?: string;
    campaignDirection?: {
      recommendedObjective?: string;
      whyThisObjective?: string;
      whatNotToChoose?: string;
      conversionEventSuggestion?: string;
      audienceStartingPoint?: string;
      creativeAngle?: string;
      landingOrTrackingWarning?: string;
      riskLevel?: string;
      confidence?: string;
      nextStep?: string;
    };
    campaignPlan?: string;
    decisions?: string[];
    reviewSchedule?: string;
    artifacts?: Array<{
      kind: string;
      title: string;
    }>;
  };
}
