import type { GuideRequestValidationPolicy } from "./guideRequestValidation";

export const GUIDE_CONTEXT_KINDS = new Set([
  "ads_command_center",
  "ad_mission",
  "offer_readiness",
  "channel_recommendation",
  "campaign_plan",
  "platform_manager",
  "platform_guided_setup",
  "platform_preflight_audit",
  "platform_reporting",
  "unknown_platform",
  "meta_ads_manager",
  "guided_setup",
  "creative_review",
  "preflight_audit",
  "performance_review",
  "unclear",
  "other",
]);

export const GUIDE_ARTIFACT_KINDS = new Set([
  "campaignPlan",
  "creativePack",
  "preflightAudit",
  "optimizationDecision",
  "trackingChecklist",
]);

export const GUIDE_DECISIONS = new Set([
  "safe_to_continue",
  "continue_with_warning",
  "fix_before_publish",
  "needs_more_signal",
  "do_not_publish",
  "manual_confirmation_required",
]);

export const GUIDE_RISK_LEVELS = new Set(["low", "medium", "high", "critical"]);
export const GUIDE_CONFIDENCE_LEVELS = new Set(["low", "medium", "high"]);
export const GUIDE_SCREEN_STATES = new Set(["loading", "recognized", "unknown", "blocked"]);

export const GUIDE_GROUNDING_TARGET_ROLES = new Set([
  "button",
  "field",
  "menu",
  "table",
  "modal",
  "alert",
  "cta",
  "link",
  "tab",
  "toggle",
  "other",
]);

export const GUIDE_GROUNDING_TARGET_RISKS = new Set(["low", "medium", "high", "restricted"]);

export const GUIDE_GROUNDING_CONTAINERS = new Set([
  "modal",
  "table",
  "sidebar",
  "main_content",
  "toolbar",
  "popover",
  "dialog",
  "unknown",
]);

export const GUIDE_GROUNDING_TARGET_STATES = new Set([
  "enabled",
  "disabled",
  "selected",
  "focused",
  "empty",
  "filled",
  "warning",
  "open",
  "closed",
  "expanded",
  "collapsed",
  "loading",
  "unknown",
]);

export const GUIDE_GROUNDING_TARGET_AFFORDANCES = new Set([
  "click",
  "type",
  "select",
  "read",
  "scroll",
  "wait",
  "confirm_manually",
]);

export const GUIDE_POINT_AFFORDANCES = new Set(["click", "select"]);

export const GUIDE_ACTION_RISKS = new Set([
  "reversible",
  "navigation",
  "selection",
  "input",
  "read_only",
  "wait",
  "spend_boundary",
  "publish_boundary",
  "billing_boundary",
  "auth_boundary",
  "policy_boundary",
  "destructive",
  "unknown",
]);

export const GUIDE_DOT_ACTION_RISKS = new Set(["reversible", "navigation", "selection", "input"]);
export const GUIDE_GROUNDING_TARGET_STABILITIES = new Set(["new", "stable", "stale", "changed", "unknown"]);
export const GUIDE_STALE_TARGET_STABILITIES = new Set(["stale", "changed"]);
export const GUIDE_VISIBLE_MODAL_CONTAINERS = new Set(["modal", "dialog", "popover"]);
export const GUIDE_SCENE_GRAPH_Z_INDEX_HINTS = new Set(["front", "middle", "back", "unknown"]);

export const GUIDE_POINT_EXPECTED_OUTCOMES = new Set([
  "stage_advanced",
  "screen_advanced",
  "modal_opened",
  "modal_closed",
  "dropdown_opened",
  "item_selected",
  "tile_selected",
  "field_focused",
  "field_filled",
  "button_enabled",
  "button_disabled",
  "wizard_advanced",
  "warning_appeared",
  "warning_cleared",
  "state_changed",
  "unknown",
]);

export const GUIDE_POINT_AUDITOR_DECISION_KEYS = new Set([
  "pointIsVisuallyInsideTarget",
  "targetLabelMatches",
  "blockedByModal",
  "targetLooksClickable",
  "shouldAcceptPoint",
  "reason",
]);

export const GROUNDING_CORROBORATION_SOURCES = new Set([
  "openai_vision",
  "local_ocr",
  "macos_accessibility",
  "browser_metadata",
  "cursor_metadata",
]);

export const GUIDE_POINT_REJECTION_REASONS = new Set([
  "point_outside_region",
  "target_confidence_low",
  "target_stale_after_screen_change",
  "blocked_target_overlap",
  "modal_context_mismatch",
  "affordance_not_clickable",
  "region_implausible",
  "semantic_signature_changed",
  "target_occluded",
  "element_missing",
  "element_confidence_low",
  "outcome_failed",
  "outcome_stale",
  "sensitive_grounding_text",
  "sensor_fusion_contradicted",
]);

export const GUIDE_LOADING_SCREEN_ID = "loading_screen";
export const GUIDE_LOADING_STAGE_ID = "loading";
export const GUIDE_UNKNOWN_SCREEN_ID = "unknown_screen";
export const GUIDE_UNKNOWN_STAGE_ID = "unknown_stage";

export const POINT_RESTRICTED_SCREEN_IDS = new Set([
  "login",
  "two_factor_auth_checkpoint",
  "budget_and_schedule",
  "review_publish",
  "billing_payment",
  "account_quality_policy",
  "reporting_delivery",
]);

export const POINT_RESTRICTED_STAGE_IDS = new Set([
  "authenticate",
  "budget_boundary",
  "billing_boundary",
  "policy_boundary",
  "manual_publish_boundary",
  "publish_boundary",
  "preflight_audit",
  "72h_review",
]);

export const UNSAFE_POINT_LABEL_PATTERN =
  /(?:\b(?:publish|submit|launch|budget|spend|billing|payment|pay|card|bank|tax|invoice|pause|delete|remove|discard|deactivate|duplicate|password|credential|recovery|appeal|verify|verification)\b|2fa|2-factor|two[-\s]?factor|auth(?:entication)?\s+code|verification\s+code|security\s+code|account\s+quality|business\s+verification|domain\s+verification)/i;

export const SENSITIVE_GUIDE_EVIDENCE_PATTERN =
  /(?:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\b(?:\d[ -]?){12,19}\b|\b\d{6,8}\b|\b(?:bearer|token|password|secret|api[_ -]?key|sk-[A-Za-z0-9_-]+|pk_live_[A-Za-z0-9_-]+)\b)/i;

export const GUIDE_SOURCE_TYPES = new Set([
  "official_rule",
  "official_definition",
  "official_guidance",
  "spider_playbook",
  "user_context",
  "mixed",
]);

export const GUIDE_REQUEST_VALIDATION_POLICY: GuideRequestValidationPolicy = {
  expectedOutcomes: GUIDE_POINT_EXPECTED_OUTCOMES,
  sensitiveEvidencePattern: SENSITIVE_GUIDE_EVIDENCE_PATTERN,
  unsafePointLabelPattern: UNSAFE_POINT_LABEL_PATTERN,
};
