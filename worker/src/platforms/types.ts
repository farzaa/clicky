export type PlatformId = "meta_ads" | "unknown_platform";

export type PlatformDetectionConfidence = "low" | "medium" | "high";

export type PlatformContextSource = "app" | "screen" | "user" | "unknown";

export interface SpiderPlatformRequestContext {
  candidatePlatformId?: string;
  source?: PlatformContextSource | string;
  visibleURLHost?: string | null;
}

export interface PlatformScreenTaxonomyItem {
  screenId: string;
  description: string;
  semanticRole: string;
  visualIntentCues: string[];
  semanticDecisionHints: string[];
  safetyTreatment: string;
  pointingPolicy: string;
  workflowStages: string[];
}

export interface PlatformWorkflowStage {
  stageId: string;
  displayName: string;
  goal: string;
}

export interface PlatformKnowledgeSourceReference {
  id: string;
  title: string;
  sourceURL: string;
  sourceType: string;
  status: string;
  topics: string[];
}

export interface PlatformCapability {
  id: string;
  description: string;
  safetyBoundary: string;
}

export type SemanticGroundingTargetRole =
  | "button"
  | "field"
  | "menu"
  | "table"
  | "modal"
  | "alert"
  | "cta"
  | "link"
  | "tab"
  | "toggle"
  | "other";

export type SemanticGroundingTargetRisk = "low" | "medium" | "high" | "restricted";
export type SemanticGroundingContainer =
  | "modal"
  | "table"
  | "sidebar"
  | "main_content"
  | "toolbar"
  | "popover"
  | "dialog"
  | "unknown";
export type SemanticGroundingTargetState =
  | "enabled"
  | "disabled"
  | "selected"
  | "empty"
  | "filled"
  | "warning"
  | "loading"
  | "unknown";
export type SemanticGroundingTargetAffordance =
  | "click"
  | "type"
  | "select"
  | "read"
  | "scroll"
  | "wait"
  | "confirm_manually";
export type SemanticGroundingTargetStability = "new" | "stable" | "stale" | "changed" | "unknown";
export type SemanticGroundingZIndexHint = "front" | "middle" | "back" | "unknown";
export type SemanticGroundingExpectedOutcome =
  | "stage_advanced"
  | "modal_opened"
  | "item_selected"
  | "state_changed"
  | "unknown";
export type GroundingCorroborationSource =
  | "openai_vision"
  | "local_ocr"
  | "macos_accessibility"
  | "browser_metadata"
  | "cursor_metadata";

export interface SemanticGroundingRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface SemanticGroundingTarget {
  elementId: string | null;
  label: string;
  role: SemanticGroundingTargetRole;
  container: SemanticGroundingContainer;
  parentLabel: string | null;
  nearestText: string[];
  semanticIntent: string;
  state: SemanticGroundingTargetState;
  risk: SemanticGroundingTargetRisk;
  targetConfidence: PlatformDetectionConfidence;
  evidence: string[];
  affordance: SemanticGroundingTargetAffordance;
  targetStability: SemanticGroundingTargetStability;
  region: SemanticGroundingRegion | null;
}

export interface SemanticSceneGraphElement {
  id: string;
  label: string;
  role: string;
  containerId: string | null;
  parentId: string | null;
  zIndexHint: SemanticGroundingZIndexHint;
  occluded: boolean;
  region: SemanticGroundingRegion | null;
  confidence: PlatformDetectionConfidence;
  evidence: string[];
}

export interface SemanticScreenGrounding {
  groundingRevision: string;
  semanticSignature: string;
  elements: SemanticSceneGraphElement[];
  visibleConcepts: string[];
  interactiveTargets: SemanticGroundingTarget[];
  blockedTargets: SemanticGroundingTarget[];
  uncertainty: string[];
}

export type PlatformBestPracticeSafetyLevel =
  | "safe_to_suggest"
  | "confirm_before_action"
  | "manual_boundary"
  | "blocked";

export interface PlatformBestPracticeRule {
  id: string;
  stageIds: string[];
  missionSignals: string[];
  recommendation: string;
  neverDo: string[];
  evidenceNeeded: string[];
  safetyLevel: PlatformBestPracticeSafetyLevel;
  sourceType: string;
  sourceIds: string[];
  reviewedAt: string;
}

export interface PlatformPack {
  platformId: PlatformId;
  displayName: string;
  knownDomains: string[];
  knownURLs: string[];
  screenTaxonomy: PlatformScreenTaxonomyItem[];
  workflowStages: PlatformWorkflowStage[];
  officialKnowledgeSources: PlatformKnowledgeSourceReference[];
  playbookRules: string[];
  safetyBoundaries: string[];
  supportedActions: string[];
  unsupportedActions: string[];
  capabilities: PlatformCapability[];
  knowledgeSummary: () => Record<string, unknown>;
}

export interface PlatformDetectionInput {
  userTranscript: string;
  platformContext?: SpiderPlatformRequestContext;
  adMissionSnapshot?: {
    recommendedChannel?: unknown;
  };
  screenshotLabels: string[];
}

export interface ScreenStageDetectionResult {
  screenId: string;
  stageId: string;
  confidence: PlatformDetectionConfidence;
  evidence: string[];
}

export interface PlatformDetectionResult {
  pack: PlatformPack;
  confidence: PlatformDetectionConfidence;
  evidence: string[];
  screenStage: ScreenStageDetectionResult;
}
