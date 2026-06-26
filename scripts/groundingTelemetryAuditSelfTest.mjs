import { parseEvents } from "./groundingTelemetryAuditParser.mjs";
import { assertPrivacySafe } from "./groundingTelemetryAuditPrivacy.mjs";
import { buildSummary } from "./groundingTelemetryAuditSummary.mjs";

const forbiddenSelfTestKeys = [
  ["visibleText", "forbidden_visible_text_key"],
  ["screenshot", "forbidden_screenshot_key"],
  ["transcript", "forbidden_transcript_key"],
  ["prompt", "forbidden_prompt_key"],
  ["modelResponse", "forbidden_model_response_key"],
  ["email", "forbidden_email_key"],
  ["token", "forbidden_token_key"],
  ["targetElementId", "forbidden_target_element_id_key"],
];

function assertSelfTestCondition(condition, message) {
  if (!condition) {
    throw new Error(`Telemetry audit self-test failed: ${message}`);
  }
}

function assertSelfTestThrows(callback, pattern, message) {
  try {
    callback();
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error);
    if (pattern.test(text)) {
      return;
    }
    throw new Error(`Telemetry audit self-test failed: ${message}: ${text}`);
  }
  throw new Error(`Telemetry audit self-test failed: ${message}`);
}

export function runTelemetryAuditSelfTest() {
  const events = parseEvents(
    [
      "Spider metric: grounding_point_accepted:platform=meta_ads:stageId=objective:screenState=recognized:screenConfidence=high:targetElementIdHash=target_hash:actionRisk=reversible:fastPathDecision=accepted:timeToDotMs=120:screenshotCaptureLatencyMs=11:groundingSchemaVersion=1",
    ].join("\n")
  );
  const summary = buildSummary(events);
  assertSelfTestCondition(summary.events === 1, "expected one accepted event");
  assertSelfTestCondition(summary.byStage.objective === 1, "expected objective stage count");
  assertSelfTestCondition(summary.visualIntelligence.fastPathAccepted === 1, "expected accepted fast path");
  assertSelfTestCondition(summary.timeToDotMs.p50 === 120, "expected time-to-dot latency summary");
  assertSelfTestCondition(
    summary.sensorLatencyP95.screenshotCapture === 11,
    "expected screenshot capture latency metadata summary"
  );

  for (const [key] of forbiddenSelfTestKeys) {
    assertSelfTestThrows(
      () => assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { [key]: "private value" },
      }),
      new RegExp(`(?:Unexpected|Forbidden) telemetry key: ${key}`),
      `expected ${key} to be rejected`
    );
  }
  for (const [value, expectedName] of [
    ["founder@example.com", "email_value"],
    ["Bearer sk_live_privatevalue123456789", "bearer_token_value"],
    ["data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA", "data_image_value"],
  ]) {
    assertSelfTestThrows(
      () => assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { stageId: value },
      }),
      new RegExp(`Forbidden telemetry value for stageId: ${expectedName}`),
      `expected ${expectedName} to be rejected`
    );
  }
  assertSelfTestThrows(
    () => assertPrivacySafe({
      name: "grounding_unreviewed_experiment",
      fields: { platform: "meta_ads" },
    }),
    /Unexpected telemetry event: grounding_unreviewed_experiment/,
    "expected unknown events to be rejected"
  );

  return {
    ok: true,
    checked: [
      "positive_metadata_summary",
      "positive_allowed_fragment_metadata_keys",
      ...forbiddenSelfTestKeys.map(([, checkName]) => checkName),
      "forbidden_email_value",
      "forbidden_bearer_token_value",
      "forbidden_data_image_value",
      "unknown_grounding_event",
    ],
  };
}
