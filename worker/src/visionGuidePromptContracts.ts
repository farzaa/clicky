import type { PlatformDetectionResult } from "./platforms/types";
import { productFeatureContractForPrompt } from "./productFeatures";
import {
  GROUNDING_CORROBORATION_SOURCES,
  GUIDE_ACTION_RISKS,
  GUIDE_CONFIDENCE_LEVELS,
  GUIDE_DECISIONS,
  GUIDE_DOT_ACTION_RISKS,
  GUIDE_GROUNDING_CONTAINERS,
  GUIDE_GROUNDING_TARGET_AFFORDANCES,
  GUIDE_GROUNDING_TARGET_RISKS,
  GUIDE_GROUNDING_TARGET_ROLES,
  GUIDE_GROUNDING_TARGET_STABILITIES,
  GUIDE_GROUNDING_TARGET_STATES,
  GUIDE_LOADING_SCREEN_ID,
  GUIDE_LOADING_STAGE_ID,
  GUIDE_POINT_AUDITOR_DECISION_KEYS,
  GUIDE_POINT_EXPECTED_OUTCOMES,
  GUIDE_POINT_REJECTION_REASONS,
  GUIDE_RISK_LEVELS,
  GUIDE_SCENE_GRAPH_Z_INDEX_HINTS,
  GUIDE_SCREEN_STATES,
  GUIDE_SOURCE_TYPES,
  GUIDE_UNKNOWN_SCREEN_ID,
  GUIDE_UNKNOWN_STAGE_ID,
  POINT_RESTRICTED_SCREEN_IDS,
  POINT_RESTRICTED_STAGE_IDS,
} from "./guideResponseContract";

export function semanticScreenUnderstandingContractForPrompt(platformDetection: PlatformDetectionResult): string {
  return JSON.stringify({
    principle: "Vision-first, semantic-first. The platform pack is ontology plus safety contract, not a UI map.",
    source_of_truth: "Current screenshots. User transcript, conversation, Ad Mission, and session metadata are context only, never visual evidence.",
    preliminary_hint: {
      detectedScreenStage: platformDetection.screenStage,
      use: "Weak hint only. Reclassify from the screenshot when visual evidence disagrees or is insufficient.",
    },
    no_ui_map_rules: [
      "Do not depend on exact position, corner, color, pixel, layout, CSS selector, or old Meta UI structure.",
      "If Meta changed the UI but the semantic intent is clear from the screenshot, classify the intent.",
      "If semantic intent is not clear from the screenshot, return unknown and ask for confirmation.",
    ],
    required_reasoning_order: [
      "1. Produce semanticGrounding from visible pixels: scene graph elements, concepts, targets, blocked targets, and uncertainty.",
      "2. Derive workflow state from grounding: screenState, screenId, stageId, confidence, and non-sensitive evidence.",
      "3. Apply relevant best practices only after workflow state is grounded.",
      "4. Apply safety policy. Safety overrides best practices.",
      "5. Decide point eligibility last.",
    ],
    semantic_grounding_shape: {
      groundingRevision:
        "Short opaque revision string for this current screenshot analysis. Generate a fresh value when the visible grounding changes.",
      semanticSignature:
        "Short semantic summary string for the current visible UI state. The Worker will derive the canonical signature from screenId, stageId, visible containers, safe target labels, and blocked target labels.",
      elements:
        "Scene graph elements visible in the current screenshot, with id, label, role, containerId, parentId, zIndexHint, occluded, confidence, evidence, and region. This is regenerated from current pixels, not a saved UI map.",
      visibleConcepts: "Short non-sensitive visible concepts such as campaign table, objective choices, modal, alert, loading skeleton, or CTA.",
      interactiveTargets:
        "Visible controls with elementId, label, role, container, parentLabel, nearestText, semanticIntent, state, risk, targetConfidence, evidence, affordance, targetStability, and region when localizable. This is not a UI map and must be regenerated from the current screenshot.",
      blockedTargets:
        "Visible sensitive, spend-changing, publish, billing, auth, policy, irreversible, or non-actionable manual controls. Include them here instead of point with the same target fields.",
      uncertainty:
        "What is ambiguous, hidden, partially visible, stale, or not readable enough to decide.",
    },
    target_contract: {
      hierarchy:
        "container and parentLabel describe where the target lives: modal, table, sidebar, main_content, toolbar, popover, dialog, or unknown.",
      evidence:
        "nearestText and evidence are short visual cues only. Never copy emails, credentials, IDs, codes, payment values, customer names, or user-entered private data.",
      action:
        "affordance must describe what the visible target supports: click, type, select, read, scroll, wait, or confirm_manually.",
      confidence:
        "A point requires targetConfidence=high on the matched target. Medium or low target confidence means no point.",
      temporal:
        "targetStability is new, stable, stale, changed, or unknown relative to guided session context. If screenChanged=true and the target did not reappear in the current screenshot, mark stale or changed and return no point.",
      scene_graph:
        "When a target has elementId, it must refer to a visible element in elements. A point cannot use an occluded element, missing element, low-confidence element, or incompatible target/element region.",
      expected_outcome:
        "When returning point, set expectedOutcome to the most specific visible outcome: dropdown_opened, modal_opened, modal_closed, tile_selected, field_focused, field_filled, button_enabled, button_disabled, wizard_advanced, warning_appeared, warning_cleared, screen_advanced, state_changed, or unknown. Legacy stage_advanced and item_selected remain accepted for compatibility.",
      action_risk:
        "The app derives actionRisk from role, container, state, semanticIntent, risk, stageId, and expectedOutcome. Dot is only allowed for reversible, navigation, selection, or input. Spend, publish, billing, auth, policy, destructive, read_only, wait, and unknown actions must return no point.",
    },
    screen_type_heuristics: [
      "wizard: treat next/continue/back buttons as stage movement only when they are low-risk and not publish/billing/spend boundaries.",
      "table: row actions near destructive or spend-changing controls are blocked unless the safe target is visually isolated and high confidence.",
      "modal/dialog/popover: prefer targets inside the frontmost container; targets behind a visible modal are stale unless evidence proves otherwise.",
      "card/tile selection: selected state, checkbox/radio state, or equivalent visual selection evidence should confirm tile_selected.",
      "form: type/fill actions require field role, empty/focused/filled state, and no disabled/covered contradiction.",
      "dropdown: open/expanded menu/listbox/popover evidence should confirm dropdown_opened.",
      "alert/warning: warning targets are read/review unless the safe action is explicit and low risk.",
      "review/publish/billing/budget boundary: never point at publish, billing, payment, budget increase, submit, launch, delete, or irreversible controls.",
      "loading/skeleton: return loading or no point; never reuse a target from the previous revision.",
    ],
  });
}

export function screenGuidanceDecisionPipelineForPrompt(): string {
  return JSON.stringify({
    layers: [
      "Vision grounding: visible concepts, controls, fields, modals, alerts, tables, loading/error states, safe regions.",
      "Workflow state: semantic screenId/stageId derived from grounding, not layout memory.",
      "Meta best practices: stage-specific decision context selected only when relevant.",
      "Safety policy: final authority; can block points and override every recommendation.",
    ],
    vision_grounding: {
      goal: "Understand what the visible screen is asking the user to do.",
      high_confidence:
        "The screen intent and any target element are visually clear without relying on transcript wording or fixed layout.",
      medium_confidence:
        "The general screen intent is plausible, but the exact element or stage is not clear enough for a point.",
      low_confidence:
        "The screen intent is unclear, ambiguous, partially visible, or contradicted by current evidence.",
    },
    screen_stage_classification: {
      recognized:
        "Use a stable ontology screenId/stageId when semantic intent is clear and not a manual boundary.",
      unknown:
        `Use ${GUIDE_UNKNOWN_SCREEN_ID}/${GUIDE_UNKNOWN_STAGE_ID}, no point, and ask for confirmation when semantic intent is unclear.`,
      loading:
        `Use ${GUIDE_LOADING_SCREEN_ID}/${GUIDE_LOADING_STAGE_ID} only when a real spinner, skeleton, blank transition, or progress state is visible now.`,
      blocked:
        "Use blocked for sensitive, spend-changing, publish, billing, credentials, policy, locked future feature, or irreversible boundaries.",
    },
    safety_boundary_decision: {
      manual_confirmation_required: [
        "billing/payment/card/bank/tax/invoice",
        "publish/review/submit/launch",
        "budget edit/spend/bid/spending limit",
        "2FA/security checkpoint/credentials/password/recovery/security code",
        "account quality/policy appeal/business verification/domain verification",
        "pause/delete/remove/deactivate/irreversible actions",
      ],
      behavior: "Blocked boundaries require requiresManualConfirmation=true and point=null.",
    },
    point_eligibility: {
      allowed_only_if: [
        "screenState=recognized",
        "screenConfidence=high",
        "requiresManualConfirmation=false",
        "screenId/stageId is not restricted",
        "matched semanticGrounding target has targetConfidence=high",
        "matched semanticGrounding target affordance is click or select",
        "matched semanticGrounding targetStability is current, not stale or changed",
        "matched elementId is present in semanticGrounding.elements when provided",
        "matched scene graph element is not occluded and has confidence=high",
        "semanticSignature is current; previous semantic signature does not authorize stale targets",
        "point coordinates fall inside the matched target region",
        "point coordinates do not fall inside blockedTargets",
        "modal/dialog/popover targets keep points inside that visible context unless evidence explicitly says the safe target is outside",
        "point label is non-sensitive and names a reversible safe UI element",
        "point target advances the selected Ad Mission instead of a generic platform step",
        "point.missionAlignment explains the mission match without user private values",
        "coordinates are valid screenshot pixel coordinates",
      ],
      high_confidence_safe_target: "Return point coordinates. Do not replace the click dot with text-only guidance.",
      medium_or_low_confidence: "Guide with text only. No point.",
    },
  });
}

export function guideDecisionContractForPrompt(): string {
  return JSON.stringify({
    screen_states: [...GUIDE_SCREEN_STATES],
    decisions: [...GUIDE_DECISIONS],
    risk_levels: [...GUIDE_RISK_LEVELS],
    confidence_levels: [...GUIDE_CONFIDENCE_LEVELS],
    source_types: [...GUIDE_SOURCE_TYPES],
    product_features: productFeatureContractForPrompt(),
    semantic_grounding: {
      required: true,
      target_roles: [...GUIDE_GROUNDING_TARGET_ROLES],
      target_risks: [...GUIDE_GROUNDING_TARGET_RISKS],
      target_containers: [...GUIDE_GROUNDING_CONTAINERS],
      target_states: [...GUIDE_GROUNDING_TARGET_STATES],
      target_affordances: [...GUIDE_GROUNDING_TARGET_AFFORDANCES],
      target_stabilities: [...GUIDE_GROUNDING_TARGET_STABILITIES],
      action_risks: [...GUIDE_ACTION_RISKS],
      dot_action_risks: [...GUIDE_DOT_ACTION_RISKS],
      z_index_hints: [...GUIDE_SCENE_GRAPH_Z_INDEX_HINTS],
      expected_outcomes: [...GUIDE_POINT_EXPECTED_OUTCOMES],
      corroboration_sources: [...GROUNDING_CORROBORATION_SOURCES],
      point_auditor_contract: [...GUIDE_POINT_AUDITOR_DECISION_KEYS],
      rejection_reasons: [...GUIDE_POINT_REJECTION_REASONS],
      rule: "semanticGrounding is regenerated from the current screenshot. It is evidence for workflow state, not a stored UI map. The Worker derives the canonical semanticSignature and rejects points that do not match a high-confidence current target region and visible non-occluded element. Auxiliary sources can confirm or contradict Vision only; they never create a point, override screenshot evidence, or upgrade low/medium Vision confidence.",
    },
    dialogue: {
      displayText: "3-8 words unless the visible UI label is shorter",
      spokenText: "1-2 short sentences",
    },
    point_safety: {
      allowed_only_when: "screenState=recognized and screenConfidence=high",
      point_shape:
        "point.label is the visible safe UI target; point.targetElementId references the scene graph element when available; point.expectedOutcome is the visible outcome to verify after the click; point.missionAlignment is the short non-sensitive reason this target matches the selected Ad Mission.",
      unknown: `Use ${GUIDE_UNKNOWN_SCREEN_ID}/${GUIDE_UNKNOWN_STAGE_ID}, ask for confirmation, and return no point.`,
      loading: `Use ${GUIDE_LOADING_SCREEN_ID}/${GUIDE_LOADING_STAGE_ID} only when loading is visible now, and return no point.`,
      blocked_screen_ids: [...POINT_RESTRICTED_SCREEN_IDS],
      blocked_stage_ids: [...POINT_RESTRICTED_STAGE_IDS],
      blocked_behavior: "Use screenState=blocked, requiresManualConfirmation=true, and no point.",
    },
    anti_loading_stuck:
      "If screenChanged=true or forceLoadingReclassification=true, reclassify from the current screenshot and do not continue loading unless a real loading indicator is visible now.",
  });
}
