import { detectPlatformPackForGuide } from "./platforms/platformRegistry";
import type { SpiderVisionGuideRequest } from "./guideTypes";
import { spiderGuideSchema } from "./guideResponseSchema";
import {
  buildVisionGuidePrompt,
  spiderMentorInstructions,
} from "./visionGuidePrompt";

export function buildOpenAIGuideRequestPayload(
  body: SpiderVisionGuideRequest,
  visionModel: string,
  safetyIdentifier: string
): Record<string, unknown> {
  const platformDetection = detectPlatformPackForGuide({
    userTranscript: body.userTranscript,
    platformContext: body.platformContext,
    adMissionSnapshot: body.adMissionSnapshot,
    screenshotLabels: body.screenshots.map((screenshot) => screenshot.label),
  });
  const content: Array<Record<string, unknown>> = [
    {
      type: "input_text",
      text: buildVisionGuidePrompt(body, platformDetection),
    },
  ];

  for (const screenshot of body.screenshots) {
    content.push({
      type: "input_text",
      text: `${screenshot.label} (${screenshot.screenshotWidthInPixels}x${screenshot.screenshotHeightInPixels} pixels)`,
    });
    content.push({
      type: "input_image",
      image_url: `data:${screenshot.mimeType || "image/jpeg"};base64,${screenshot.imageBase64}`,
      detail: "original",
    });
  }

  return {
    model: visionModel,
    instructions: spiderMentorInstructions(platformDetection),
    input: [
      {
        role: "user",
        content,
      },
    ],
    store: false,
    safety_identifier: safetyIdentifier,
    text: {
      format: {
        type: "json_schema",
        name: "spider_guide_response",
        strict: true,
        schema: spiderGuideSchema(),
      },
    },
  };
}
