export type SpiderProductFeatureAvailability = "available" | "locked";

export type SpiderProductFeatureId =
  | "first_step_guided_setup"
  | "preflight_audit"
  | "review_72h";

interface SpiderProductFeatureDescriptor {
  id: SpiderProductFeatureId;
  displayName: string;
  availability: SpiderProductFeatureAvailability;
  promptRule: string;
  supportedAction?: string;
  unsupportedAction?: string;
  capability?: {
    id: string;
    description: string;
    safetyBoundary: string;
  };
}

export const spiderProductFeatures: Record<SpiderProductFeatureId, SpiderProductFeatureDescriptor> = {
  first_step_guided_setup: {
    id: "first_step_guided_setup",
    displayName: "First-step Guided Setup",
    availability: "available",
    promptRule: "Guided Setup is the current MVP AHA: turn the Ad Mission into one safe next setup step on the visible screen.",
    supportedAction: "Create campaign direction, guide the visible setup screen, and stop at manual publish or other irreversible boundaries.",
    capability: {
      id: "screen_guided_setup",
      description: "Step-by-step Meta Ads first-step setup from screenshots.",
      safetyBoundary: "Stop before publish, budget escalation, billing, and irreversible actions.",
    },
  },
  preflight_audit: {
    id: "preflight_audit",
    displayName: "Preflight Audit",
    availability: "locked",
    promptRule: "Preflight Audit is locked in the current MVP. Do not present it as an available action.",
    unsupportedAction: "Running Preflight Audit or telling the user to run Preflight before publishing.",
  },
  review_72h: {
    id: "review_72h",
    displayName: "72h Review",
    availability: "locked",
    promptRule: "72h Review is locked in the current MVP. Do not present it as an available action.",
    unsupportedAction: "Running 72h Review or giving post-launch optimization review as an available workflow.",
  },
};

export function productFeatureContractForPrompt(): Record<string, unknown> {
  return {
    available: availableProductFeatures().map((feature) => feature.displayName),
    locked: lockedProductFeatures().map((feature) => feature.displayName),
    v2_scope: "Automate only the first-step Guided Setup loop. Do not automate publish, spend, budget, billing, pause, delete, Preflight, or 72h Review.",
  };
}

export function productFeaturePromptSummary(): string {
  return [
    `Available now: ${availableProductFeatures().map((feature) => feature.displayName).join(", ")}.`,
    `Locked now: ${lockedProductFeatures().map((feature) => feature.displayName).join(", ")}.`,
    "Locked features must not be presented as available actions.",
    "V2 automates only first-step Guided Setup.",
  ].join(" ");
}

export function productFeaturePolicyRules(): string[] {
  return Object.values(spiderProductFeatures).map((feature) => feature.promptRule);
}

export function productFeatureSupportedActions(): string[] {
  return availableProductFeatures()
    .map((feature) => feature.supportedAction)
    .filter((action): action is string => typeof action === "string");
}

export function productFeatureUnsupportedActions(): string[] {
  return lockedProductFeatures()
    .map((feature) => feature.unsupportedAction)
    .filter((action): action is string => typeof action === "string");
}

export function productFeatureCapabilities(): Array<{ id: string; description: string; safetyBoundary: string }> {
  return availableProductFeatures()
    .map((feature) => feature.capability)
    .filter((capability): capability is { id: string; description: string; safetyBoundary: string } => capability !== undefined);
}

function availableProductFeatures(): SpiderProductFeatureDescriptor[] {
  return Object.values(spiderProductFeatures).filter((feature) => feature.availability === "available");
}

function lockedProductFeatures(): SpiderProductFeatureDescriptor[] {
  return Object.values(spiderProductFeatures).filter((feature) => feature.availability === "locked");
}
