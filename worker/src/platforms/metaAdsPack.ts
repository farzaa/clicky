import meta72hReviewPlaybook from "../../knowledge/meta_72h_review_playbook.json";
import metaAdReviewRules from "../../knowledge/meta_ad_review_rules.json";
import metaCampaignObjectives from "../../knowledge/meta_campaign_objectives.json";
import metaCreativePolicyRisks from "../../knowledge/meta_creative_policy_risks.json";
import metaDecisionTypes from "../../knowledge/meta_decision_types.json";
import metaGuidedSetupSteps from "../../knowledge/meta_guided_setup_steps.json";
import metaPreflightChecks from "../../knowledge/meta_preflight_checks.json";
import metaTrackingReadinessChecks from "../../knowledge/meta_tracking_readiness_checks.json";
import sourceRegistry from "../../knowledge/source_registry.json";
import {
  productFeatureCapabilities,
  productFeaturePolicyRules,
  productFeatureSupportedActions,
  productFeatureUnsupportedActions,
} from "../productFeatures";
import { sharedSpiderSafetyBoundaries } from "./sharedSafety";
import type { PlatformKnowledgeSourceReference, PlatformPack } from "./types";

interface SourceRegistryFile {
  sources?: Array<{
    id?: string;
    platform?: string;
    title?: string;
    source_url?: string;
    source_type?: string;
    status?: string;
    topics?: string[];
  }>;
}

const META_KNOWLEDGE_SOURCES: Record<string, unknown>[] = [
  sourceRegistry,
  metaAdReviewRules,
  metaCampaignObjectives,
  metaPreflightChecks,
  metaCreativePolicyRisks,
  metaTrackingReadinessChecks,
  meta72hReviewPlaybook,
  metaGuidedSetupSteps,
  metaDecisionTypes,
].map((source) => source as Record<string, unknown>);

export const metaAdsPlatformPack: PlatformPack = {
  platformId: "meta_ads",
  displayName: "Meta Ads",
  knownDomains: [
    "adsmanager.facebook.com",
    "business.facebook.com",
    "facebook.com",
    "meta.com",
  ],
  knownURLs: [
    "https://adsmanager.facebook.com/adsmanager/manage/campaigns",
    "https://business.facebook.com/",
    "https://www.facebook.com/business/help",
    "https://transparency.meta.com/policies/ad-standards/",
  ],
  screenTaxonomy: [
    {
      screenId: "login",
      description: "Meta login or sign-in screen before account access.",
      semanticRole: "Authentication gate before ads account access.",
      visualIntentCues: ["sign-in or login form", "credential entry", "account access prompt"],
      semanticDecisionHints: ["Classify as blocked when credentials are visible or required."],
      safetyTreatment: "blocked_sensitive_auth",
      pointingPolicy: "No point to credential fields, password controls, or recovery actions.",
      workflowStages: ["authenticate"],
    },
    {
      screenId: "two_factor_auth_checkpoint",
      description: "Two-factor authentication, login approval, security checkpoint, account recovery, or blocked authentication screen.",
      semanticRole: "Sensitive authentication checkpoint or account recovery boundary.",
      visualIntentCues: ["security verification request", "login approval", "code challenge", "recovery flow"],
      semanticDecisionHints: ["Treat security and recovery material as sensitive even when layout changes."],
      safetyTreatment: "blocked_sensitive_auth",
      pointingPolicy: "No point to codes, credential fields, recovery, or approval controls.",
      workflowStages: ["authenticate"],
    },
    {
      screenId: "account_picker",
      description: "Ad account picker, account selector, permissions selection, or ad account switcher.",
      semanticRole: "Manual account or permission selection before campaign setup.",
      visualIntentCues: ["multiple accounts or portfolios", "account switcher", "permissions choice"],
      semanticDecisionHints: ["Recognize account choice semantically; do not infer the correct account without user context."],
      safetyTreatment: "manual_safe_navigation",
      pointingPolicy: "Point only to clearly safe navigation or account-selection controls when confidence is high.",
      workflowStages: ["select_account"],
    },
    {
      screenId: "business_selection",
      description: "Business portfolio, Business Manager, business suite, or business selection entry point.",
      semanticRole: "Business portfolio selection or business manager entry point.",
      visualIntentCues: ["business portfolio choices", "business suite entry", "business manager home"],
      semanticDecisionHints: ["Help orient the user without entering billing or verification settings."],
      safetyTreatment: "manual_safe_navigation",
      pointingPolicy: "Point only to safe business selection or Ads Manager navigation controls.",
      workflowStages: ["select_account"],
    },
    {
      screenId: "ads_manager_dashboard",
      description: "Ads Manager dashboard, overview, navigation shell, or business manager home before a campaign table is visible.",
      semanticRole: "Ads management overview before campaign creation.",
      visualIntentCues: ["ads dashboard summary", "manager overview", "campaign navigation entry"],
      semanticDecisionHints: ["Use dashboard semantics to guide toward campaigns, not account settings."],
      safetyTreatment: "safe_navigation",
      pointingPolicy: "Point only to safe navigation toward campaigns or create-flow entry points.",
      workflowStages: ["open_ads_manager"],
    },
    {
      screenId: "campaign_table",
      description: "Campaigns table, campaign list, ad account campaign manager, filters, columns, search, and Create button.",
      semanticRole: "Campaign management list where a new campaign can be started.",
      visualIntentCues: ["campaign rows", "campaign list", "create campaign action", "table filters"],
      semanticDecisionHints: ["Recognize the campaign list by its purpose, not by the create action position."],
      safetyTreatment: "safe_navigation",
      pointingPolicy: "Point to a safe create-campaign entry only when clearly visible and reversible.",
      workflowStages: ["create_campaign"],
    },
    {
      screenId: "create_campaign_entry",
      description: "Create campaign modal, campaign creation entry point, buying flow start, or campaign setup method choice.",
      semanticRole: "Campaign setup start or buying-flow selection.",
      visualIntentCues: ["new campaign modal", "campaign setup method", "buying flow choice"],
      semanticDecisionHints: ["Guide the first setup step without selecting spend, budget, or publish controls."],
      safetyTreatment: "safe_setup",
      pointingPolicy: "Point to safe setup choices only when high confidence; avoid spend-related controls.",
      workflowStages: ["create_campaign"],
    },
    {
      screenId: "objective_selection",
      description: "Objective selection, campaign goal choice, sales, leads, engagement, traffic, awareness, app promotion, or objective recommendation screen.",
      semanticRole: "Campaign objective selection based on business intent.",
      visualIntentCues: ["objective choices", "campaign goal options", "sales/leads/traffic/awareness style choices"],
      semanticDecisionHints: ["Choose from semantic objective intent, not visual order or tile placement."],
      safetyTreatment: "safe_setup",
      pointingPolicy: "Point to the recommended objective only with high confidence and clear Ad Mission alignment.",
      workflowStages: ["choose_objective"],
    },
    {
      screenId: "campaign_settings",
      description: "Campaign naming, buying type, special category, and high-level campaign settings.",
      semanticRole: "High-level campaign metadata and structure configuration.",
      visualIntentCues: ["campaign name", "buying type", "special category", "campaign-level settings"],
      semanticDecisionHints: ["Guide naming and safe structure choices; treat sensitive categories conservatively."],
      safetyTreatment: "safe_setup_with_warnings",
      pointingPolicy: "Point to non-sensitive campaign setup fields when clearly safe and reversible.",
      workflowStages: ["campaign_settings"],
    },
    {
      screenId: "budget_and_schedule",
      description: "Campaign or ad set budget, daily budget, lifetime budget, spending limit, schedule, bid strategy, optimization, and delivery controls.",
      semanticRole: "Spend, budget, schedule, bid, or delivery boundary.",
      visualIntentCues: ["budget amount", "daily or lifetime spend", "schedule", "bid strategy", "spending limit"],
      semanticDecisionHints: ["Any spend-setting or budget-editing surface is a manual boundary."],
      safetyTreatment: "blocked_spend_boundary",
      pointingPolicy: "No point to budget, bid, spend, schedule, or delivery controls.",
      workflowStages: ["budget_boundary"],
    },
    {
      screenId: "audience_and_placements",
      description: "Audience, location, age, gender, detailed targeting, custom audiences, Advantage targeting, placements, and audience definition.",
      semanticRole: "Audience and placement setup.",
      visualIntentCues: ["audience definition", "location or demographic targeting", "placement options", "targeting suggestions"],
      semanticDecisionHints: ["Guide toward simple audience setup without over-fragmenting small tests."],
      safetyTreatment: "safe_setup_with_warnings",
      pointingPolicy: "Point to safe audience controls when high confidence; avoid restricted custom data or irreversible changes.",
      workflowStages: ["audience_setup"],
    },
    {
      screenId: "creative_and_destination",
      description: "Ad creative, identity, format, media, primary text, headline, description, CTA, destination URL, preview, and creative warnings.",
      semanticRole: "Creative, offer promise, CTA, and destination setup.",
      visualIntentCues: ["ad creative fields", "media or preview", "headline or primary text", "destination or CTA"],
      semanticDecisionHints: ["Check semantic alignment between offer, creative, CTA, and destination."],
      safetyTreatment: "safe_setup_with_warnings",
      pointingPolicy: "Point to safe creative or destination fields when high confidence; never expose user-entered private values.",
      workflowStages: ["creative_setup", "tracking_setup", "preflight_audit"],
    },
    {
      screenId: "tracking_conversion_event",
      description: "Pixel, dataset, conversion event, app event, website event, destination tracking, URL parameters, and attribution setup.",
      semanticRole: "Tracking, event, attribution, or conversion setup.",
      visualIntentCues: ["pixel or dataset choice", "conversion event", "tracking parameters", "attribution setup"],
      semanticDecisionHints: ["Guide event matching and tracking readiness before spend."],
      safetyTreatment: "safe_setup_with_warnings",
      pointingPolicy: "Point to safe tracking/event controls when high confidence; avoid exposing IDs or private account data.",
      workflowStages: ["tracking_setup", "preflight_audit"],
    },
    {
      screenId: "review_publish",
      description: "Review, publish, final confirmation, submit, or other spend-starting boundary.",
      semanticRole: "Final review, submit, publish, launch, or spend-starting boundary.",
      visualIntentCues: ["review summary", "publish or submit action", "final confirmation", "launch boundary"],
      semanticDecisionHints: ["Any launch or publish intent is outside the MVP and must stop."],
      safetyTreatment: "blocked_publish_boundary",
      pointingPolicy: "No point to publish, submit, launch, review confirmation, or final spend-starting controls.",
      workflowStages: ["preflight_audit", "manual_publish_boundary"],
    },
    {
      screenId: "billing_payment",
      description: "Billing, payment method, invoice, tax, card, bank, or account payment screen.",
      semanticRole: "Billing, payment, tax, invoice, card, or bank account boundary.",
      visualIntentCues: ["payment method", "billing settings", "invoice or tax fields", "card or bank fields"],
      semanticDecisionHints: ["Any billing/payment intent is sensitive and outside Spider guidance."],
      safetyTreatment: "blocked_billing_boundary",
      pointingPolicy: "No point to billing, payment, tax, card, bank, or invoice controls.",
      workflowStages: ["billing_boundary"],
    },
    {
      screenId: "account_quality_policy",
      description: "Account Quality, policy warning, ad rejection, business verification, domain verification, or policy appeal screen.",
      semanticRole: "Policy, account quality, appeal, or verification boundary.",
      visualIntentCues: ["policy warning", "account quality", "ad rejection", "verification request", "appeal action"],
      semanticDecisionHints: ["Treat policy and verification flows as manual boundaries with no guarantees."],
      safetyTreatment: "blocked_policy_boundary",
      pointingPolicy: "No point to appeals, verification, account quality actions, or policy-submission controls.",
      workflowStages: ["policy_boundary"],
    },
    {
      screenId: "reporting_delivery",
      description: "Campaign delivery table, metrics, charts, breakdowns, and post-launch review.",
      semanticRole: "Post-launch reporting or delivery analysis surface.",
      visualIntentCues: ["campaign metrics", "delivery status", "charts or breakdowns", "post-launch performance table"],
      semanticDecisionHints: ["72h Review is locked; do not present optimization review as available."],
      safetyTreatment: "blocked_locked_future_feature",
      pointingPolicy: "No point for post-launch optimization workflows in the current MVP.",
      workflowStages: ["72h_review"],
    },
  ],
  workflowStages: [
    {
      stageId: "authenticate",
      displayName: "Authenticate",
      goal: "Get the user into Meta safely without reading or repeating credentials, codes, or recovery material.",
    },
    {
      stageId: "select_account",
      displayName: "Select Account",
      goal: "Help the user pick the correct business portfolio or ad account without touching billing or sensitive account settings.",
    },
    {
      stageId: "open_ads_manager",
      displayName: "Open Ads Manager",
      goal: "Enter the campaigns surface before giving setup advice.",
    },
    {
      stageId: "choose_objective",
      displayName: "Choose Objective",
      goal: "Match the platform objective to the Ad Mission.",
    },
    {
      stageId: "campaign_settings",
      displayName: "Campaign Settings",
      goal: "Keep structure and naming tied to the offer and decision memory.",
    },
    {
      stageId: "budget_boundary",
      displayName: "Budget Boundary",
      goal: "Review budget manually and never escalate spend.",
    },
    {
      stageId: "billing_boundary",
      displayName: "Billing Boundary",
      goal: "Stop before billing, payment, tax, card, or bank account changes.",
    },
    {
      stageId: "policy_boundary",
      displayName: "Policy Boundary",
      goal: "Treat account quality, policy appeal, and verification screens as manual confirmation zones.",
    },
    {
      stageId: "manual_publish_boundary",
      displayName: "Manual Publish Boundary",
      goal: "Stop before publish, submit, or any spend-starting confirmation.",
    },
    {
      stageId: "audience_setup",
      displayName: "Audience Setup",
      goal: "Start from the planned audience without over-fragmenting small tests.",
    },
    {
      stageId: "creative_setup",
      displayName: "Creative Setup",
      goal: "Keep the promise, creative angle, CTA, and destination aligned.",
    },
    {
      stageId: "tracking_setup",
      displayName: "Tracking Setup",
      goal: "Check event and destination readiness before spend.",
    },
    {
      stageId: "preflight_audit",
      displayName: "Preflight Audit",
      goal: "Stop before publish and separate official rules from Spider judgment.",
    },
    {
      stageId: "72h_review",
      displayName: "72h Review",
      goal: "Read early signal conservatively without pretending weak data is proof.",
    },
  ],
  officialKnowledgeSources: metaOfficialKnowledgeSources(),
  playbookRules: [
    ...productFeaturePolicyRules(),
    "Guided Setup starts from the visible Ads Manager screen, not from generic chat.",
    "When the user is on login or account selection, point only to the next safe navigation control and never read or repeat credentials, codes, billing, or account recovery details.",
    "Do not keep calling a screen loading after dashboard, account picker, campaign table, or setup UI text is visible.",
    "Choose the campaign objective from the Ad Mission and fix objective mismatch before publishing.",
    "Budget is a manual boundary. Point and explain; never change it for the user.",
    "Keep audience setup simple enough for the planned test budget to gather signal.",
    "Creative, CTA, destination, and tracking must match the offer promise before spend.",
  ],
  safetyBoundaries: [
    ...sharedSpiderSafetyBoundaries,
    "For Meta Ads billing, payment, policy appeal, account quality, business verification, domain verification, publish, pause, deletion, or budget changes, require manual confirmation and stop before the action.",
  ],
  supportedActions: [
    "Read the visible Meta Ads screen.",
    "Identify likely Ads Manager screen and setup stage.",
    "Distinguish login, 2FA/auth checkpoint, account picker, business selection, dashboard, campaign table, create campaign, objective, campaign settings, budget, audience, creative, tracking, review/publish, billing/payment, account quality/policy, and reporting screens.",
    "Point to a visible button, field, or warning when confidence is sufficient.",
    "Explain one safe next manual step.",
    ...productFeatureSupportedActions(),
    "Use official Meta rules only when grounded in the loaded source inventory.",
  ],
  unsupportedActions: [
    ...productFeatureUnsupportedActions(),
    "Publishing campaigns.",
    "Changing budgets, bid strategy, spend limits, or billing settings.",
    "Clicking buttons or filling fields for the user.",
    "Pausing, deleting, duplicating, or editing live campaigns automatically.",
    "Guaranteeing policy approval, delivery, conversions, ROAS, CPA, or performance.",
    "Treating Spider playbook advice as an official Meta rule.",
  ],
  capabilities: [
    ...productFeatureCapabilities(),
    {
      id: "artifact_generation",
      description: "Campaign plans, creative packs, decisions, and tracking checklists.",
      safetyBoundary: "Generate only when the screen and Ad Mission justify durable output.",
    },
  ],
  knowledgeSummary: metaKnowledgeSummary,
};

function metaOfficialKnowledgeSources(): PlatformKnowledgeSourceReference[] {
  const registry = sourceRegistry as SourceRegistryFile;
  return (registry.sources ?? [])
    .filter((source) => source.platform === "meta_ads" && (source.source_type ?? "").startsWith("official"))
    .map((source) => ({
      id: source.id ?? "unknown_source",
      title: source.title ?? "Untitled source",
      sourceURL: source.source_url ?? "",
      sourceType: source.source_type ?? "official_guidance",
      status: source.status ?? "unknown",
      topics: Array.isArray(source.topics) ? source.topics.filter((topic): topic is string => typeof topic === "string") : [],
    }));
}

function metaKnowledgeSummary(): Record<string, unknown> {
  return {
    principle: "Official rules never decide alone. Independent playbooks never pretend to be official policy.",
    source_integrity:
      "Use sourceType honestly: official_rule, official_definition, official_guidance, spider_playbook, user_context, or mixed. If a source is missing, stale, or unclear, be conservative.",
    sources: META_KNOWLEDGE_SOURCES.map((source) => ({
      kind: stringValue(source.kind) || "UnknownKnowledge",
      platform: stringValue(source.platform) || "meta_ads",
      topic: stringValue(source.topic) || "unknown",
      retrieved_at: stringValue(source.retrieved_at) || "unknown",
      last_verified_at: stringValue(source.last_verified_at) || "unknown",
      status: stringValue(source.status) || "unknown",
    })),
  };
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}
