import type { SpiderVisionGuideRequest } from "./guideTypes";
import { validateVisionGuideRequest } from "./guideRequestValidation";
import { jsonResponse } from "./http";
import {
  parseJSONText,
  readBoundedRequestText,
} from "./payloadSecurity";
import {
  consumeQuota,
  consumeRequestRateLimits,
  requirePaidUser,
} from "./authRoutes";
import { recordAuditEvent } from "./auditEventStore";
import {
  configuredOpenAIModel,
  numericEnv,
  requireOpenAISecret,
} from "./runtimeConfig";
import { requestOpenAIGuideOutputText } from "./openAIGuideClient";
import { buildOpenAIGuideRequestPayload } from "./openAIGuideRequest";
import { GUIDE_REQUEST_VALIDATION_POLICY } from "./guideResponseContract";
import { guideResponsePayload } from "./guideResponseValidation";
import { guideValidationContextForRequest } from "./guideValidationContext";

export async function handleVisionGuide(request: Request, env: Env): Promise<Response> {
  const user = await requirePaidUser(request, env);
  const maxPayloadBytes = numericEnv(env.MAX_SCREENSHOT_PAYLOAD_BYTES, 8_000_000);
  const rawBody = await readBoundedRequestText(request, maxPayloadBytes, "Screenshot payload is too large.");

  const body = parseJSONText<SpiderVisionGuideRequest>(rawBody, "Invalid Spider guide request.");
  validateVisionGuideRequest(body, GUIDE_REQUEST_VALIDATION_POLICY);
  const openAIAPIKey = requireOpenAISecret(env);
  const visionModel = configuredOpenAIModel(env.OPENAI_VISION_MODEL, "gpt-5.5", "OpenAI vision model");

  await consumeRequestRateLimits(request, env, "vision", {
    ipLimit: numericEnv(env.DAILY_IP_VISION_LIMIT, 160),
    deviceLimit: numericEnv(env.DAILY_DEVICE_VISION_LIMIT, 80),
  });
  await consumeQuota(env, user.id, "vision", numericEnv(env.DAILY_VISION_LIMIT, 40));
  await recordAuditEvent(env, user.id, "vision_guide_requested");

  const outputText = await requestOpenAIGuideOutputText({
    apiKey: openAIAPIKey,
    payload: buildOpenAIGuideRequestPayload(body, visionModel, user.emailHash),
    safetyIdentifier: user.emailHash,
  });

  return jsonResponse(guideResponsePayload(outputText, guideValidationContextForRequest(body)));
}
