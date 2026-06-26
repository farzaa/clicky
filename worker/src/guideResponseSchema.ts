import {
  MAX_GUIDE_GROUNDING_TARGETS,
  MAX_GUIDE_GROUNDING_UNCERTAINTIES,
  MAX_GUIDE_GROUNDING_VISIBLE_CONCEPTS,
  MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
} from "./guideLimits";
import {
  GUIDE_ARTIFACT_KINDS,
  GUIDE_CONFIDENCE_LEVELS,
  GUIDE_CONTEXT_KINDS,
  GUIDE_DECISIONS,
  GUIDE_GROUNDING_CONTAINERS,
  GUIDE_GROUNDING_TARGET_AFFORDANCES,
  GUIDE_GROUNDING_TARGET_RISKS,
  GUIDE_GROUNDING_TARGET_ROLES,
  GUIDE_GROUNDING_TARGET_STABILITIES,
  GUIDE_GROUNDING_TARGET_STATES,
  GUIDE_POINT_EXPECTED_OUTCOMES,
  GUIDE_RISK_LEVELS,
  GUIDE_SCENE_GRAPH_Z_INDEX_HINTS,
  GUIDE_SCREEN_STATES,
  GUIDE_SOURCE_TYPES,
} from "./guideResponseContract";

export function spiderGuideSchema(): Record<string, unknown> {
  return {
    type: "object",
    additionalProperties: false,
    required: [
      "spokenText",
      "displayText",
      "nextStep",
      "semanticGrounding",
      "screenState",
      "screenId",
      "stageId",
      "screenConfidence",
      "screenEvidence",
      "shouldContinuePolling",
      "pollAfterMs",
      "contextKind",
      "officialRule",
      "spiderJudgment",
      "decision",
      "riskLevel",
      "confidence",
      "sourceType",
      "requiresManualConfirmation",
      "reviewTrigger",
      "decisionMemoryUpdate",
      "point",
      "adMissionUpdate",
      "artifact",
    ],
    properties: {
      spokenText: { type: "string" },
      displayText: { type: "string" },
      nextStep: { type: "string" },
      semanticGrounding: semanticGroundingSchema(),
      screenState: {
        type: "string",
        enum: [...GUIDE_SCREEN_STATES],
      },
      screenId: { type: "string" },
      stageId: { type: "string" },
      screenConfidence: {
        type: "string",
        enum: [...GUIDE_CONFIDENCE_LEVELS],
      },
      screenEvidence: {
        type: "array",
        maxItems: MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
        items: { type: "string" },
      },
      shouldContinuePolling: { type: "boolean" },
      pollAfterMs: { anyOf: [{ type: "integer" }, { type: "null" }] },
      contextKind: {
        type: "string",
        enum: [...GUIDE_CONTEXT_KINDS],
      },
      officialRule: { anyOf: [{ type: "string" }, { type: "null" }] },
      spiderJudgment: { type: "string" },
      decision: {
        type: "string",
        enum: [...GUIDE_DECISIONS],
      },
      riskLevel: {
        type: "string",
        enum: [...GUIDE_RISK_LEVELS],
      },
      confidence: {
        type: "string",
        enum: [...GUIDE_CONFIDENCE_LEVELS],
      },
      sourceType: {
        type: "string",
        enum: [...GUIDE_SOURCE_TYPES],
      },
      requiresManualConfirmation: { type: "boolean" },
      reviewTrigger: { anyOf: [{ type: "string" }, { type: "null" }] },
      decisionMemoryUpdate: { anyOf: [{ type: "string" }, { type: "null" }] },
      point: {
        anyOf: [
          { type: "null" },
          {
            type: "object",
            additionalProperties: false,
            required: [
              "x",
              "y",
              "label",
              "screenNumber",
              "missionAlignment",
              "targetElementId",
              "expectedOutcome",
            ],
            properties: {
              x: { type: "number" },
              y: { type: "number" },
              label: { anyOf: [{ type: "string" }, { type: "null" }] },
              screenNumber: { anyOf: [{ type: "integer" }, { type: "null" }] },
              missionAlignment: { anyOf: [{ type: "string" }, { type: "null" }] },
              targetElementId: { anyOf: [{ type: "string" }, { type: "null" }] },
              expectedOutcome: {
                type: "string",
                enum: [...GUIDE_POINT_EXPECTED_OUTCOMES],
              },
            },
          },
        ],
      },
      artifact: {
        anyOf: [
          { type: "null" },
          {
            type: "object",
            additionalProperties: false,
            required: ["kind", "title", "markdown"],
            properties: {
              kind: {
                type: "string",
                enum: [...GUIDE_ARTIFACT_KINDS],
              },
              title: { type: "string" },
              markdown: { type: "string" },
            },
          },
        ],
      },
      adMissionUpdate: {
        anyOf: [
          { type: "null" },
          {
            type: "object",
            additionalProperties: false,
            required: [
              "offer",
              "targetAudience",
              "ticket",
              "country",
              "language",
              "budget",
              "businessObjective",
              "landingPageURL",
              "recommendedChannel",
              "campaignPlan",
              "decisions",
              "reviewSchedule",
            ],
            properties: {
              offer: { anyOf: [{ type: "string" }, { type: "null" }] },
              targetAudience: { anyOf: [{ type: "string" }, { type: "null" }] },
              ticket: { anyOf: [{ type: "string" }, { type: "null" }] },
              country: { anyOf: [{ type: "string" }, { type: "null" }] },
              language: { anyOf: [{ type: "string" }, { type: "null" }] },
              budget: { anyOf: [{ type: "string" }, { type: "null" }] },
              businessObjective: { anyOf: [{ type: "string" }, { type: "null" }] },
              landingPageURL: { anyOf: [{ type: "string" }, { type: "null" }] },
              recommendedChannel: { anyOf: [{ type: "string" }, { type: "null" }] },
              campaignPlan: { anyOf: [{ type: "string" }, { type: "null" }] },
              decisions: {
                anyOf: [
                  { type: "array", items: { type: "string" } },
                  { type: "null" },
                ],
              },
              reviewSchedule: { anyOf: [{ type: "string" }, { type: "null" }] },
            },
          },
        ],
      },
    },
  };
}

function semanticGroundingSchema(): Record<string, unknown> {
  const regionSchema = {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["x", "y", "width", "height"],
        properties: {
          x: { type: "number" },
          y: { type: "number" },
          width: { type: "number" },
          height: { type: "number" },
        },
      },
    ],
  };

  const elementSchema = {
    type: "object",
    additionalProperties: false,
    required: [
      "id",
      "label",
      "role",
      "containerId",
      "parentId",
      "zIndexHint",
      "occluded",
      "region",
      "confidence",
      "evidence",
    ],
    properties: {
      id: { type: "string" },
      label: { type: "string" },
      role: { type: "string" },
      containerId: { anyOf: [{ type: "string" }, { type: "null" }] },
      parentId: { anyOf: [{ type: "string" }, { type: "null" }] },
      zIndexHint: {
        type: "string",
        enum: [...GUIDE_SCENE_GRAPH_Z_INDEX_HINTS],
      },
      occluded: { type: "boolean" },
      region: regionSchema,
      confidence: {
        type: "string",
        enum: [...GUIDE_CONFIDENCE_LEVELS],
      },
      evidence: {
        type: "array",
        maxItems: MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
        items: { type: "string" },
      },
    },
  };

  const targetSchema = {
    type: "object",
    additionalProperties: false,
    required: [
      "elementId",
      "label",
      "role",
      "container",
      "parentLabel",
      "nearestText",
      "semanticIntent",
      "state",
      "risk",
      "targetConfidence",
      "evidence",
      "affordance",
      "targetStability",
      "region",
    ],
    properties: {
      elementId: { anyOf: [{ type: "string" }, { type: "null" }] },
      label: { type: "string" },
      role: {
        type: "string",
        enum: [...GUIDE_GROUNDING_TARGET_ROLES],
      },
      container: {
        type: "string",
        enum: [...GUIDE_GROUNDING_CONTAINERS],
      },
      parentLabel: { anyOf: [{ type: "string" }, { type: "null" }] },
      nearestText: {
        type: "array",
        maxItems: MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
        items: { type: "string" },
      },
      semanticIntent: { type: "string" },
      state: {
        type: "string",
        enum: [...GUIDE_GROUNDING_TARGET_STATES],
      },
      risk: {
        type: "string",
        enum: [...GUIDE_GROUNDING_TARGET_RISKS],
      },
      targetConfidence: {
        type: "string",
        enum: [...GUIDE_CONFIDENCE_LEVELS],
      },
      evidence: {
        type: "array",
        maxItems: MAX_GUIDE_SCREEN_EVIDENCE_ITEMS,
        items: { type: "string" },
      },
      affordance: {
        type: "string",
        enum: [...GUIDE_GROUNDING_TARGET_AFFORDANCES],
      },
      targetStability: {
        type: "string",
        enum: [...GUIDE_GROUNDING_TARGET_STABILITIES],
      },
      region: regionSchema,
    },
  };

  return {
    type: "object",
    additionalProperties: false,
    required: [
      "groundingRevision",
      "semanticSignature",
      "elements",
      "visibleConcepts",
      "interactiveTargets",
      "blockedTargets",
      "uncertainty",
    ],
    properties: {
      groundingRevision: { type: "string" },
      semanticSignature: { type: "string" },
      elements: {
        type: "array",
        maxItems: MAX_GUIDE_GROUNDING_TARGETS * 3,
        items: elementSchema,
      },
      visibleConcepts: {
        type: "array",
        maxItems: MAX_GUIDE_GROUNDING_VISIBLE_CONCEPTS,
        items: { type: "string" },
      },
      interactiveTargets: {
        type: "array",
        maxItems: MAX_GUIDE_GROUNDING_TARGETS,
        items: targetSchema,
      },
      blockedTargets: {
        type: "array",
        maxItems: MAX_GUIDE_GROUNDING_TARGETS,
        items: targetSchema,
      },
      uncertainty: {
        type: "array",
        maxItems: MAX_GUIDE_GROUNDING_UNCERTAINTIES,
        items: { type: "string" },
      },
    },
  };
}
