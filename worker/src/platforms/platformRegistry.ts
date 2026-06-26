import { metaAdsPlatformPack } from "./metaAdsPack";
import { unknownPlatformPack } from "./unknownPlatformPack";
import type { PlatformDetectionInput, PlatformDetectionResult, PlatformId, PlatformPack } from "./types";

const PLATFORM_PACKS: Record<PlatformId, PlatformPack> = {
  meta_ads: metaAdsPlatformPack,
  unknown_platform: unknownPlatformPack,
};

export function detectPlatformPackForGuide(input: PlatformDetectionInput): PlatformDetectionResult {
  const candidatePack = platformPackForId(input.platformContext?.candidatePlatformId);
  if (candidatePack && candidatePack.platformId !== "unknown_platform") {
    return {
      pack: candidatePack,
      confidence: "high",
      evidence: [`app_candidate:${candidatePack.platformId}`],
      screenStage: detectScreenStageForPack(input, candidatePack),
    };
  }

  const visibleURLHost = normalizedString(input.platformContext?.visibleURLHost);
  if (visibleURLHost) {
    const hostPack = platformPackForHost(visibleURLHost);
    if (hostPack) {
      return {
        pack: hostPack,
        confidence: "high",
        evidence: [`visible_host:${visibleURLHost}`],
        screenStage: detectScreenStageForPack(input, hostPack),
      };
    }
  }

  const textEvidence = [
    input.userTranscript,
    normalizedString(input.adMissionSnapshot?.recommendedChannel),
    ...input.screenshotLabels,
  ].join(" ");
  const inferredPack = platformPackForText(textEvidence);
  if (inferredPack) {
    return {
      pack: inferredPack,
      confidence: "medium",
      evidence: ["text_or_mission_hint"],
      screenStage: detectScreenStageForPack(input, inferredPack),
    };
  }

  return {
    pack: unknownPlatformPack,
    confidence: "low",
    evidence: candidatePack?.platformId === "unknown_platform" ? ["app_candidate:unknown_platform"] : ["no_reliable_platform_match"],
    screenStage: detectScreenStageForPack(input, unknownPlatformPack),
  };
}

export function platformContextForPrompt(detection: PlatformDetectionResult): string {
  const pack = detection.pack;
  return JSON.stringify({
    detectedPlatform: {
      platformId: pack.platformId,
      displayName: pack.displayName,
      confidence: detection.confidence,
      evidence: detection.evidence,
    },
    detectedScreenStage: detection.screenStage,
    platformPack: {
      platformId: pack.platformId,
      displayName: pack.displayName,
      knownDomains: pack.knownDomains,
      knownURLs: pack.knownURLs,
      screenTaxonomy: pack.screenTaxonomy,
      workflowStages: pack.workflowStages,
      officialKnowledgeSources: pack.officialKnowledgeSources,
      playbookRules: pack.playbookRules,
      safetyBoundaries: pack.safetyBoundaries,
      supportedActions: pack.supportedActions,
      unsupportedActions: pack.unsupportedActions,
      capabilities: pack.capabilities,
    },
  });
}

export function platformKnowledgeSummaryForPrompt(pack: PlatformPack): string {
  return JSON.stringify(pack.knowledgeSummary());
}

function detectScreenStageForPack(input: PlatformDetectionInput, pack: PlatformPack) {
  const textEvidence = normalizedString([
    input.platformContext?.visibleURLHost,
    ...input.screenshotLabels,
  ].join(" "));

  if (!textEvidence) {
    return fallbackScreenStage(pack);
  }

  for (const taxonomyItem of pack.screenTaxonomy) {
    const screenTokens = [
      taxonomyItem.screenId,
      taxonomyItem.description,
      ...taxonomyItem.workflowStages,
    ].map(readableToken);
    if (screenTokens.some((token) => token.length > 0 && textEvidence.includes(token))) {
      return {
        screenId: taxonomyItem.screenId,
        stageId: taxonomyItem.workflowStages[0] ?? "unknown_stage",
        confidence: "medium" as const,
        evidence: ["text_or_label_stage_hint"],
      };
    }
  }

  for (const stage of pack.workflowStages) {
    const stageTokens = [stage.stageId, stage.displayName].map(readableToken);
    if (stageTokens.some((token) => token.length > 0 && textEvidence.includes(token))) {
      return {
        screenId: "unknown_screen",
        stageId: stage.stageId,
        confidence: "medium" as const,
        evidence: ["text_or_label_stage_hint"],
      };
    }
  }

  return fallbackScreenStage(pack);
}

function platformPackForId(value: unknown): PlatformPack | null {
  const platformId = normalizedPlatformId(value);
  return platformId ? PLATFORM_PACKS[platformId] : null;
}

function platformPackForHost(host: string): PlatformPack | null {
  const normalizedHost = normalizedString(host);
  for (const pack of Object.values(PLATFORM_PACKS)) {
    if (pack.platformId === "unknown_platform") {
      continue;
    }
    if (pack.knownDomains.some((domain) => normalizedHost === domain || normalizedHost.endsWith(`.${domain}`))) {
      return pack;
    }
  }
  return null;
}

function platformPackForText(value: string): PlatformPack | null {
  const normalizedValue = normalizedString(value);
  if (!normalizedValue) {
    return null;
  }

  for (const pack of Object.values(PLATFORM_PACKS)) {
    if (pack.platformId === "unknown_platform") {
      continue;
    }
    const tokens = [
      pack.platformId,
      pack.displayName,
      ...pack.knownDomains,
      ...pack.knownURLs,
    ].map(normalizedString);

    if (tokens.some((token) => token.length > 0 && normalizedValue.includes(token))) {
      return pack;
    }
  }

  return null;
}

function normalizedPlatformId(value: unknown): PlatformId | null {
  const normalizedValue = normalizedString(value).replace(/[-\s]+/g, "_");
  if (normalizedValue === "meta_ads" || normalizedValue === "unknown_platform") {
    return normalizedValue;
  }
  return null;
}

function normalizedString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function readableToken(value: string): string {
  return normalizedString(value).replace(/[_-]+/g, " ");
}

function fallbackScreenStage(pack: PlatformPack) {
  if (pack.platformId !== "unknown_platform") {
    return {
      screenId: "unknown_screen",
      stageId: "unknown_stage",
      confidence: "low" as const,
      evidence: ["no_reliable_screen_stage_match"],
    };
  }

  return {
    screenId: pack.screenTaxonomy[0]?.screenId ?? "unknown_screen",
    stageId: pack.workflowStages[0]?.stageId ?? "unknown_stage",
    confidence: "low" as const,
    evidence: ["no_reliable_screen_stage_match"],
  };
}
