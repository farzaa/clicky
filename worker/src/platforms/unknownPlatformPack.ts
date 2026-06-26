import { sharedSpiderSafetyBoundaries } from "./sharedSafety";
import type { PlatformPack } from "./types";

export const unknownPlatformPack: PlatformPack = {
  platformId: "unknown_platform",
  displayName: "Unknown Ads Platform",
  knownDomains: [],
  knownURLs: [],
  screenTaxonomy: [
    {
      screenId: "unknown_or_untrusted_screen",
      description: "A visible screen that has not matched a trusted platform pack with enough confidence.",
      semanticRole: "Unknown or untrusted ads surface.",
      visualIntentCues: ["unclear platform identity", "insufficient trusted platform evidence"],
      semanticDecisionHints: ["Ask for confirmation instead of inventing platform-specific meaning."],
      safetyTreatment: "unknown_fail_closed",
      pointingPolicy: "No point unless a generic safe navigation control is unambiguous.",
      workflowStages: ["visual_orientation"],
    },
    {
      screenId: "generic_login_or_account_gate",
      description: "Login, account picker, permission prompt, or setup gate that should be handled conservatively.",
      semanticRole: "Generic access gate or account selection boundary.",
      visualIntentCues: ["login form", "permission prompt", "account selection", "setup gate"],
      semanticDecisionHints: ["Treat credentials and account recovery as sensitive even without a platform match."],
      safetyTreatment: "generic_sensitive_boundary",
      pointingPolicy: "No point to credentials, codes, recovery, billing, or account-sensitive controls.",
      workflowStages: ["visual_orientation"],
    },
    {
      screenId: "generic_ads_dashboard",
      description: "A dashboard-like surface where Spider can read visible labels but should not assume product-specific semantics.",
      semanticRole: "Generic ads dashboard or reporting-like surface.",
      visualIntentCues: ["dashboard summary", "ads metrics", "campaign-like list", "manager navigation"],
      semanticDecisionHints: ["Use visible labels conservatively and ask for confirmation before platform-specific guidance."],
      safetyTreatment: "generic_conservative_guidance",
      pointingPolicy: "Point only to clearly safe, reversible navigation with high confidence.",
      workflowStages: ["visual_orientation"],
    },
  ],
  workflowStages: [
    {
      stageId: "visual_orientation",
      displayName: "Visual Orientation",
      goal: "Use visible labels only and avoid pretending the platform is known.",
    },
  ],
  officialKnowledgeSources: [],
  playbookRules: [
    "Do not assume Meta, TikTok, Google, X, or any other platform when detection confidence is low.",
    "Use only visible UI text, user-stated context, and universal safety boundaries.",
    "Give one conservative next step, usually a safe navigation or clarification step.",
    "If a field or button is ambiguous, do not point with certainty.",
  ],
  safetyBoundaries: sharedSpiderSafetyBoundaries,
  supportedActions: [
    "Read visible UI labels.",
    "Explain generic advertising concepts only at a high level.",
    "Point to a clearly visible safe navigation control when confidence is sufficient.",
    "Ask the user to confirm platform or goal when needed.",
  ],
  unsupportedActions: [
    "Applying platform-specific policy, objective, billing, tracking, or optimization rules.",
    "Claiming the screen is Meta Ads, TikTok Ads, X Ads, Google Ads, or another platform without evidence.",
    "Giving publish, budget, billing, or irreversible-account guidance beyond stopping and asking for manual confirmation.",
    "Creating platform-specific artifacts from weak screen evidence.",
  ],
  capabilities: [
    {
      id: "general_visual_guidance",
      description: "Conservative screen reading and safe next-step guidance.",
      safetyBoundary: "No platform-specific claims unless the screen or user gives reliable evidence.",
    },
  ],
  knowledgeSummary: () => ({
    principle: "Unknown platform mode is conservative by design.",
    source_integrity:
      "There are no official platform-specific sources loaded for this screen. Use visible UI only and lower confidence.",
    sources: [],
  }),
};
