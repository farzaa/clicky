import type { PlatformBestPracticeRule } from "./types";

interface MetaAdsBestPracticeSelectionInput {
  screenId: string;
  stageId: string;
  adMissionSnapshot?: Record<string, unknown>;
}

const META_ADS_BEST_PRACTICES_REVIEWED_AT = "2026-06-18";
const MAX_PROMPT_RULES = 5;
const UNKNOWN_STAGE_IDS = new Set(["", "unknown_stage", "loading"]);

const META_ADS_BEST_PRACTICE_RULES: readonly PlatformBestPracticeRule[] = [
  {
    id: "campaign_table_start_from_create",
    stageIds: ["open_ads_manager", "create_campaign"],
    missionSignals: ["guided_setup", "first_campaign"],
    recommendation: "Start from the campaign creation flow only when the Campaigns surface and a reversible Create/New campaign entry are visible.",
    neverDo: ["open billing settings", "edit live campaigns", "duplicate live campaigns"],
    evidenceNeeded: ["campaign list or ads manager navigation", "safe create campaign entry"],
    safetyLevel: "safe_to_suggest",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "objective_match_mission",
    stageIds: ["choose_objective"],
    missionSignals: ["recommended_objective", "business_objective", "sales", "leads", "traffic", "awareness"],
    recommendation: "Choose the visible objective that matches the Campaign Direction; do not pick an objective because it appears first or looks visually prominent.",
    neverDo: ["choose objective from layout order", "choose traffic for a sales mission without explicit user intent"],
    evidenceNeeded: ["visible objective choices", "Ad Mission business objective or recommendedObjective"],
    safetyLevel: "safe_to_suggest",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "sales_objective_for_sales_mission",
    stageIds: ["choose_objective"],
    missionSignals: ["sales", "purchase", "buyer", "checkout", "paid offer"],
    recommendation: "For a direct sales mission with ready tracking and destination, prefer Sales over visit-oriented objectives.",
    neverDo: ["optimize a purchase mission for cheap visits"],
    evidenceNeeded: ["sales mission signal", "Sales objective visible"],
    safetyLevel: "safe_to_suggest",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "leads_objective_for_lead_mission",
    stageIds: ["choose_objective"],
    missionSignals: ["lead", "consultation", "qualified contact", "form submission"],
    recommendation: "For a lead-generation mission, prefer Leads when the first business outcome is a qualified contact or form submission.",
    neverDo: ["optimize a lead mission for awareness unless the user explicitly wants reach"],
    evidenceNeeded: ["lead mission signal", "Leads objective visible"],
    safetyLevel: "safe_to_suggest",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "campaign_settings_keep_structure_readable",
    stageIds: ["campaign_settings"],
    missionSignals: ["offer", "objective", "decision_memory"],
    recommendation: "Keep campaign naming and high-level structure tied to the offer, objective, and test date so later review is not a mess.",
    neverDo: ["use private client data in names", "change special category without clear user confirmation"],
    evidenceNeeded: ["campaign name or high-level settings visible", "offer or objective context"],
    safetyLevel: "safe_to_suggest",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "budget_is_manual_boundary",
    stageIds: ["budget_boundary"],
    missionSignals: ["budget", "spend", "test limit"],
    recommendation: "Review budget against the Ad Mission, but do not point to or change budget, bid, schedule, or spend controls automatically.",
    neverDo: ["increase budget", "edit bid strategy", "change schedule", "change spend limit"],
    evidenceNeeded: ["budget or schedule controls visible"],
    safetyLevel: "manual_boundary",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "audience_keep_signal_concentrated",
    stageIds: ["audience_setup"],
    missionSignals: ["targetAudience", "country", "language", "audienceStartingPoint"],
    recommendation: "Start from the planned audience and avoid over-fragmenting early tests; small budgets need enough signal in one place.",
    neverDo: ["upload customer lists", "use private seed data", "create excessive audience splits for a small test"],
    evidenceNeeded: ["audience controls visible", "planned audience, country, or language"],
    safetyLevel: "confirm_before_action",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "creative_offer_cta_destination_alignment",
    stageIds: ["creative_setup"],
    missionSignals: ["offer", "creativeAngle", "landingPageURL", "cta"],
    recommendation: "Keep the ad promise, creative angle, CTA, and destination aligned before moving toward spend.",
    neverDo: ["repeat private user-entered creative values", "ignore destination mismatch", "promise an outcome the landing page does not support"],
    evidenceNeeded: ["creative fields, preview, CTA, or destination visible", "offer or landing page context"],
    safetyLevel: "confirm_before_action",
    sourceType: "mixed",
    sourceIds: ["meta_advertising_standards_main", "spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "tracking_event_match_mission",
    stageIds: ["tracking_setup"],
    missionSignals: ["conversionEventSuggestion", "sales", "leads", "tracking", "pixel", "dataset"],
    recommendation: "Use the conversion event that matches the mission; weak or mismatched tracking should stop the launch path before publish.",
    neverDo: ["publish with mismatched event", "repeat pixel IDs or private account IDs", "invent tracking readiness"],
    evidenceNeeded: ["tracking, pixel, dataset, or event controls visible", "mission event suggestion"],
    safetyLevel: "confirm_before_action",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "review_stop_before_publish",
    stageIds: ["preflight_audit", "manual_publish_boundary", "publish_boundary"],
    missionSignals: ["publish", "review", "submit", "launch"],
    recommendation: "At review or publish, stop and explain the manual spend boundary; Spider can advise but the user must publish themselves.",
    neverDo: ["point to publish", "submit campaign", "launch campaign", "start spend"],
    evidenceNeeded: ["review summary, publish, submit, or launch boundary visible"],
    safetyLevel: "manual_boundary",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "billing_payment_blocked",
    stageIds: ["billing_boundary"],
    missionSignals: ["billing", "payment", "card", "tax", "invoice", "bank"],
    recommendation: "Billing and payment are sensitive account boundaries; tell the user to handle them directly in Meta.",
    neverDo: ["point to card fields", "point to payment method", "read invoices", "change billing settings"],
    evidenceNeeded: ["billing, payment, card, invoice, tax, or bank controls visible"],
    safetyLevel: "blocked",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "auth_checkpoint_blocked",
    stageIds: ["authenticate"],
    missionSignals: ["login", "2fa", "security", "verification", "recovery"],
    recommendation: "Authentication, 2FA, and recovery screens are sensitive; orient the user without reading values or pointing to credential/code fields.",
    neverDo: ["point to password fields", "read 2FA codes", "repeat recovery material", "submit credentials"],
    evidenceNeeded: ["login, security, verification, or recovery prompt visible"],
    safetyLevel: "blocked",
    sourceType: "spider_playbook",
    sourceIds: ["spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
  {
    id: "policy_verification_manual_boundary",
    stageIds: ["policy_boundary"],
    missionSignals: ["policy", "account quality", "appeal", "verification"],
    recommendation: "Policy, account quality, appeal, and verification screens are manual boundaries; do not promise approval or point to submissions.",
    neverDo: ["point to appeal", "submit verification", "guarantee policy approval"],
    evidenceNeeded: ["policy, account quality, appeal, or verification UI visible"],
    safetyLevel: "manual_boundary",
    sourceType: "mixed",
    sourceIds: ["meta_advertising_standards_main", "spider_ads_playbook_v1"],
    reviewedAt: META_ADS_BEST_PRACTICES_REVIEWED_AT,
  },
];

export function metaAdsBestPracticesForPrompt(input: MetaAdsBestPracticeSelectionInput): string | null {
  const stageId = normalizedString(input.stageId);
  const screenId = normalizedString(input.screenId);
  if (UNKNOWN_STAGE_IDS.has(stageId)) {
    return null;
  }

  const missionSignals = missionSignalsFromSnapshot(input.adMissionSnapshot);
  const selectedRules = META_ADS_BEST_PRACTICE_RULES
    .filter((rule) => rule.stageIds.some((candidateStageId) => normalizedString(candidateStageId) === stageId))
    .sort((a, b) => ruleScore(b, missionSignals) - ruleScore(a, missionSignals))
    .slice(0, MAX_PROMPT_RULES);

  if (selectedRules.length === 0) {
    return null;
  }

  return JSON.stringify({
    principle:
      "Meta Ads best practices are decision context after Vision grounding and workflow classification. They do not recognize the UI and never authorize unsafe pointing.",
    selectionBasis: {
      screenId,
      stageId,
      missionSignals,
      ruleCount: selectedRules.length,
      selectionWarning:
        "These rules were selected from the current stage hint. If the screenshot proves a different stage, ignore nonmatching rules and use the screenshot as truth.",
    },
    safetyPrecedence:
      "Safety policy overrides Meta best practices. Restricted, sensitive, unknown, loading, low-confidence, spend, billing, auth, policy, and publish boundaries must return no point.",
    rules: selectedRules.map((rule) => ({
      id: rule.id,
      stageIds: rule.stageIds,
      missionSignals: rule.missionSignals,
      recommendation: rule.recommendation,
      neverDo: rule.neverDo,
      evidenceNeeded: rule.evidenceNeeded,
      safetyLevel: rule.safetyLevel,
      sourceType: rule.sourceType,
      sourceIds: rule.sourceIds,
      reviewedAt: rule.reviewedAt,
    })),
  });
}

export function metaAdsBestPracticeRules(): readonly PlatformBestPracticeRule[] {
  return META_ADS_BEST_PRACTICE_RULES;
}

function ruleScore(rule: PlatformBestPracticeRule, missionSignals: string[]): number {
  const missionSignalSet = new Set(missionSignals.map(normalizedString));
  return rule.missionSignals.reduce((score, signal) => {
    const normalizedSignal = normalizedString(signal);
    return missionSignalSet.has(normalizedSignal) ? score + 1 : score;
  }, 0);
}

function missionSignalsFromSnapshot(snapshot: Record<string, unknown> | undefined): string[] {
  const signals = new Set<string>();
  const flattened = flattenMissionSnapshot(snapshot).join(" ").toLowerCase();
  const candidates = [
    "sales",
    "purchase",
    "buyer",
    "checkout",
    "lead",
    "consultation",
    "qualified contact",
    "form submission",
    "traffic",
    "awareness",
    "budget",
    "targetAudience",
    "country",
    "language",
    "creativeAngle",
    "landingPageURL",
    "conversionEventSuggestion",
    "tracking",
    "pixel",
    "dataset",
  ];

  for (const candidate of candidates) {
    if (flattened.includes(candidate.toLowerCase())) {
      signals.add(candidate);
    }
  }

  return [...signals].slice(0, 12);
}

function flattenMissionSnapshot(value: unknown): string[] {
  if (typeof value === "string") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.flatMap(flattenMissionSnapshot);
  }
  if (value && typeof value === "object") {
    return Object.values(value).flatMap(flattenMissionSnapshot);
  }
  return [];
}

function normalizedString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}
