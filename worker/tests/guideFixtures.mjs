export function validGuideOutput(overrides = {}) {
  return {
    spokenText: "Choose the objective that matches this campaign.",
    displayText: "Choose objective.",
    nextStep: "Select the objective that matches the Ad Mission.",
    semanticGrounding: semanticGroundingForPointLabels([
      "Objective option",
      "Audience field",
      "Creative preview",
      "Conversion event",
      "Leads",
    ]),
    screenState: "recognized",
    screenId: "objective_selection",
    stageId: "choose_objective",
    screenConfidence: "high",
    screenEvidence: ["Objective options visible"],
    shouldContinuePolling: true,
    pollAfterMs: null,
    contextKind: "platform_guided_setup",
    officialRule: null,
    spiderJudgment: "The campaign objective should match the Ad Mission before setup continues.",
    decision: "safe_to_continue",
    riskLevel: "low",
    confidence: "high",
    sourceType: "spider_playbook",
    requiresManualConfirmation: false,
    reviewTrigger: null,
    decisionMemoryUpdate: null,
    point: null,
    adMissionUpdate: null,
    artifact: null,
    ...overrides,
  };
}

export function semanticGroundingForPointLabels(labels) {
  const interactiveTargets = labels.map((label) => semanticGroundingTarget(label));
  return {
    groundingRevision: "test-grounding-revision",
    semanticSignature: "model-provided-signature",
    elements: interactiveTargets.map((target) => semanticGroundingElement(target.label, {
      id: target.elementId,
      region: target.region,
    })),
    visibleConcepts: ["Objective options visible"],
    interactiveTargets,
    blockedTargets: [],
    uncertainty: [],
  };
}

export function semanticGroundingTarget(label, overrides = {}) {
  return {
    elementId: testElementId(label),
    label,
    role: "button",
    container: "main_content",
    parentLabel: "Campaign objective",
    nearestText: [label],
    semanticIntent: label,
    state: "enabled",
    risk: "low",
    targetConfidence: "high",
    evidence: [`${label} visible`],
    affordance: "click",
    targetStability: "stable",
    region: {
      x: 100,
      y: 120,
      width: 80,
      height: 32,
    },
    ...overrides,
  };
}

export function semanticGroundingElement(label, overrides = {}) {
  return {
    id: testElementId(label),
    label,
    role: "button",
    containerId: null,
    parentId: null,
    zIndexHint: "front",
    occluded: false,
    region: {
      x: 100,
      y: 120,
      width: 80,
      height: 32,
    },
    confidence: "high",
    evidence: [`${label} visible`],
    ...overrides,
  };
}

export function guidePoint(overrides = {}) {
  const label = overrides.label || "Objective option";
  return {
    x: 120,
    y: 140,
    label,
    screenNumber: 1,
    missionAlignment: "Matches mission objective",
    targetElementId: testElementId(label),
    expectedOutcome: "item_selected",
    ...overrides,
  };
}

export function testElementId(label) {
  return `element_${String(label).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "") || "target"}`;
}

export function validVisionGuideBody(overrides = {}) {
  return {
    userTranscript: "What should I do now?",
    screenshots: [
      {
        label: "Main display",
        imageBase64: "AQIDBA==",
        mimeType: "image/jpeg",
        isCursorScreen: true,
        displayWidthInPoints: 1440,
        displayHeightInPoints: 900,
        screenshotWidthInPixels: 2880,
        screenshotHeightInPixels: 1800,
      },
    ],
    ...overrides,
  };
}

export function paidUserRow(overrides = {}) {
  return {
    id: "user_test",
    email_hash: "email_hash_test",
    entitlement_status: "active",
    stripe_customer_id: "cus_test",
    stripe_subscription_id: "sub_test",
    subscription_status: "active",
    subscription_current_period_end: Math.floor(Date.now() / 1000) + 86_400,
    cancel_at_period_end: 0,
    ...overrides,
  };
}

export function unpaidUserRow(overrides = {}) {
  return paidUserRow({
    entitlement_status: "none",
    stripe_customer_id: null,
    stripe_subscription_id: null,
    subscription_status: null,
    subscription_current_period_end: null,
    cancel_at_period_end: 0,
    ...overrides,
  });
}
