import { recordAuditEvent } from "./auditEventStore";
import {
  consumeQuota,
  consumeRequestRateLimits,
  requirePaidUser,
} from "./authRoutes";
import { HttpError, jsonResponse } from "./http";
import {
  parseJSONText,
  readBoundedResponseText,
} from "./payloadSecurity";
import {
  configuredOpenAIModel,
  numericEnv,
  requireOpenAISecret,
} from "./runtimeConfig";
import {
  asRecord,
  numberOrNull,
  stringOrNull,
} from "./structuredValues";

const MAX_REALTIME_SECRET_RESPONSE_BYTES = 65_536;
const OPENAI_CLIENT_SECRET_VALUE_PATTERN = /^[\x21-\x7E]{1,4096}$/;

export async function createRealtimeClientSecret(request: Request, env: Env): Promise<Response> {
  const user = await requirePaidUser(request, env);
  const openAIAPIKey = requireOpenAISecret(env);
  const realtimeModel = configuredOpenAIModel(env.OPENAI_REALTIME_MODEL, "gpt-realtime-2", "OpenAI Realtime model");
  await consumeRequestRateLimits(request, env, "realtime", {
    ipLimit: numericEnv(env.DAILY_IP_REALTIME_LIMIT, 180),
    deviceLimit: numericEnv(env.DAILY_DEVICE_REALTIME_LIMIT, 90),
  });
  await consumeQuota(env, user.id, "realtime", numericEnv(env.DAILY_REALTIME_LIMIT, 60));
  await recordAuditEvent(env, user.id, "realtime_client_secret_requested");

  const openAIResponse = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      authorization: `Bearer ${openAIAPIKey}`,
      "content-type": "application/json",
      "OpenAI-Safety-Identifier": user.emailHash,
    },
    body: JSON.stringify({
      expires_after: {
        anchor: "created_at",
        seconds: 600,
      },
      session: {
        type: "realtime",
        model: realtimeModel,
        instructions: realtimeInstructions(),
        output_modalities: ["audio"],
        audio: {
          input: {
            format: {
              type: "audio/pcm",
              rate: 24000,
            },
            transcription: {
              model: "gpt-4o-mini-transcribe",
            },
            turn_detection: {
              type: "server_vad",
            },
          },
          output: {
            format: {
              type: "audio/pcm",
              rate: 24000,
            },
            voice: "alloy",
            speed: 1.0,
          },
        },
      },
    }),
  });

  const responseText = await readBoundedResponseText(
    openAIResponse,
    MAX_REALTIME_SECRET_RESPONSE_BYTES,
    "OpenAI realtime response is too large."
  );
  if (!openAIResponse.ok) {
    throw new HttpError(openAIResponse.status, "Could not create Realtime client secret.");
  }

  return jsonResponse(realtimeClientSecretPayload(responseText, realtimeModel));
}

function realtimeInstructions(): string {
  return "You are Spider's low-latency voice layer for paid ads guidance. Use short dialogue only: max 2 short sentences. The visual guide endpoint owns deep screen reasoning and first-step setup guidance; ask for screen guidance when the user needs visual direction.";
}

function realtimeClientSecretPayload(responseText: string, realtimeModel: string): Record<string, unknown> {
  const parsed = parseJSONText(responseText, "OpenAI returned an invalid realtime response.", 502);
  const payload = asRecord(parsed);
  const nestedClientSecret = asRecord(payload.client_secret);
  const clientSecretValues = [payload.value, nestedClientSecret.value]
    .filter((value): value is string => typeof value === "string");
  const clientSecretValue = stringOrNull(nestedClientSecret.value) || stringOrNull(payload.value);
  const expiresAt = numberOrNull(nestedClientSecret.expires_at) ?? numberOrNull(payload.expires_at);

  if (!clientSecretValue || clientSecretValues.length === 0) {
    throw new HttpError(502, "OpenAI returned no Realtime client secret.");
  }
  if (!clientSecretValues.every((value) => OPENAI_CLIENT_SECRET_VALUE_PATTERN.test(value))) {
    throw new HttpError(502, "OpenAI returned an invalid Realtime client secret.");
  }

  return {
    client_secret: {
      value: clientSecretValue,
      ...(expiresAt !== null ? { expires_at: expiresAt } : {}),
    },
    model: realtimeModel,
  };
}
