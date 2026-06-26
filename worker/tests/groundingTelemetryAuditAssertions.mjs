import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";

function swiftEnumStringRawValues(source, enumName) {
  const enumMatch = source.match(new RegExp(`enum ${enumName}: String \\{([\\s\\S]*?)\\n\\}`));
  assert.ok(enumMatch, `Missing Swift enum ${enumName}`);
  return [...enumMatch[1].matchAll(/case\s+\w+\s*=\s*"([^"]+)"/g)].map((match) => match[1]).sort();
}

function swiftSetStringValues(source, setName) {
  const setMatch = source.match(new RegExp(`${setName}: Set<String> = \\[([\\s\\S]*?)\\n\\s*\\]`));
  assert.ok(setMatch, `Missing Swift Set ${setName}`);
  return [...setMatch[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]).sort();
}

function javascriptSetStringValues(source, setName) {
  const setMatch = source.match(new RegExp(`${setName} = new Set\\(\\[([\\s\\S]*?)\\]\\);`));
  assert.ok(setMatch, `Missing JS Set ${setName}`);
  return [...setMatch[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]).sort();
}

export function registerGroundingTelemetryAuditAssertions({ test, workerRoot }) {
  test("grounding telemetry audit is CLI-only and privacy allowlisted", () => {
    const auditScriptSource = readFileSync(
      path.join(workerRoot, "..", "scripts", "grounding_telemetry_audit.mjs"),
      "utf8"
    );
    const auditParserSource = readFileSync(
      path.join(workerRoot, "..", "scripts", "groundingTelemetryAuditParser.mjs"),
      "utf8"
    );
    const auditPrivacySource = readFileSync(
      path.join(workerRoot, "..", "scripts", "groundingTelemetryAuditPrivacy.mjs"),
      "utf8"
    );
    const auditSummarySource = readFileSync(
      path.join(workerRoot, "..", "scripts", "groundingTelemetryAuditSummary.mjs"),
      "utf8"
    );
    const auditSelfTestSource = readFileSync(
      path.join(workerRoot, "..", "scripts", "groundingTelemetryAuditSelfTest.mjs"),
      "utf8"
    );
    const combinedAuditSource = [
      auditScriptSource,
      auditParserSource,
      auditPrivacySource,
      auditSummarySource,
      auditSelfTestSource,
    ].join("\n");
    const groundingTelemetrySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetry.swift"),
      "utf8"
    );
    const groundingTelemetrySanitizerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetrySanitizer.swift"),
      "utf8"
    );

    assert.match(auditPrivacySource, /allowedKeys = new Set/);
    assert.match(auditPrivacySource, /allowedEventNames = new Set/);
    assert.match(combinedAuditSource, /grounding_frame_analyzed/);
    assert.match(combinedAuditSource, /grounding_sensor_fusion_evaluated/);
    assert.match(auditPrivacySource, /Unexpected telemetry event/);
    assert.match(auditPrivacySource, /forbiddenKeyFragments/);
    assert.match(combinedAuditSource, /totalPointDecisionLatencyMs/);
    assert.match(combinedAuditSource, /timeToDotMs/);
    assert.match(auditSummarySource, /sensorLatencyP95/);
    assert.match(combinedAuditSource, /targetFingerprint/);
    assert.match(combinedAuditSource, /regionPlausibility/);
    assert.match(auditSummarySource, /fusionDecisions/);
    assert.match(auditSummarySource, /outcomes/);
    assert.match(auditSummarySource, /rejections/);
    assert.match(auditSummarySource, /sensorContradictionRate/);
    assert.match(auditSummarySource, /dotAvailabilityByStage/);
    assert.match(auditSummarySource, /falseBlockReviewQueue/);
    assert.match(auditSummarySource, /shadowCandidates/);
    assert.match(auditSummarySource, /preDotVerificationRequired/);
    assert.match(auditSummarySource, /preDotVerificationTimeout/);
    assert.match(auditSummarySource, /dotSuppressedByLatency/);
    assert.match(auditSummarySource, /fastPathAccepted/);
    assert.match(auditSummarySource, /fastPathBlocked/);
    assert.match(auditSummarySource, /actionRisks/);
    assert.match(auditSummarySource, /calibrationDecisions/);
    assert.match(auditSummarySource, /p95/);
    assert.match(auditParserSource, /export function parseMetricLine\(line\)/);
    assert.match(auditParserSource, /export function parseEvents\(input\)/);
    assert.match(auditPrivacySource, /export function assertPrivacySafe\(event\)/);
    assert.match(auditSummarySource, /export function buildSummary\(events\)/);
    assert.match(auditSelfTestSource, /export function runTelemetryAuditSelfTest\(\)/);
    assert.match(auditScriptSource, /export function runTelemetryAuditCLI\(\)/);
    assert.match(auditScriptSource, /JSON\.stringify\(buildSummary\(events\), null, 2\)/);
    assert.match(auditScriptSource, /import\.meta\.url === pathToFileURL\(process\.argv\[1\]\)\.href/);
    assert.doesNotMatch(combinedAuditSource, /SwiftUI|NSView|dashboard|replay visual|product UI/i);
    assert.deepEqual(
      javascriptSetStringValues(auditPrivacySource, "allowedEventNames"),
      swiftEnumStringRawValues(groundingTelemetrySource, "SpiderGroundingTelemetryEventName")
    );
    assert.deepEqual(
      javascriptSetStringValues(auditPrivacySource, "allowedKeys"),
      swiftSetStringValues(groundingTelemetrySanitizerSource, "allowedPayloadKeys")
    );
  });

  test("grounding telemetry audit exposes pure parsing and summary functions", async () => {
    const auditScriptPath = path.join(workerRoot, "..", "scripts", "grounding_telemetry_audit.mjs");
    const audit = await import(pathToFileURL(auditScriptPath).href);
    const events = audit.parseEvents(
      "Spider grounding: grounding_sensor_fusion_evaluated:platform=meta_ads:stageId=objective:screenState=recognized:screenConfidence=high:fusionDecision=weakly_confirmed:sensorFusionLatencyMs=42:latencyMs=42:screenChanged=true\n"
    );

    assert.equal(events.length, 1);
    assert.equal(events[0].name, "grounding_sensor_fusion_evaluated");
    assert.equal(events[0].fields.stageId, "objective");
    const summary = audit.buildSummary(events);
    assert.equal(summary.events, 1);
    assert.equal(summary.byStage.objective, 1);
    assert.equal(summary.fusionDecisions.weakly_confirmed, 1);
    assert.equal(summary.latencyMs.p50, 42);
    const selfTestResult = audit.runTelemetryAuditSelfTest();
    assert.equal(selfTestResult.ok, true);
    assert.deepEqual(selfTestResult.checked, [
      "positive_metadata_summary",
      "positive_allowed_fragment_metadata_keys",
      "forbidden_visible_text_key",
      "forbidden_screenshot_key",
      "forbidden_transcript_key",
      "forbidden_prompt_key",
      "forbidden_model_response_key",
      "forbidden_email_key",
      "forbidden_token_key",
      "forbidden_target_element_id_key",
      "forbidden_email_value",
      "forbidden_bearer_token_value",
      "forbidden_data_image_value",
      "unknown_grounding_event",
    ]);
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { visibleText: "private value" },
      }),
      /Unexpected telemetry key: visibleText/
    );
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_unreviewed_experiment",
        fields: { platform: "meta_ads" },
      }),
      /Unexpected telemetry event: grounding_unreviewed_experiment/
    );
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { targetElementId: "raw-button-id" },
      }),
      /Unexpected telemetry key: targetElementId/
    );
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { screenshot: "private value" },
      }),
      /Unexpected telemetry key: screenshot/
    );
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { token: "private value" },
      }),
      /Unexpected telemetry key: token/
    );
    assert.doesNotThrow(() => audit.assertPrivacySafe({
      name: "grounding_point_accepted",
      fields: {
        targetElementIdHash: "hashed-target-id",
        screenshotCaptureLatencyMs: "12",
      },
    }));
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { stageId: "founder@example.com" },
      }),
      /Forbidden telemetry value for stageId: email_value/
    );
    assert.throws(
      () => audit.assertPrivacySafe({
        name: "grounding_point_rejected",
        fields: { stageId: "Bearer sk_live_privatevalue123456789" },
      }),
      /Forbidden telemetry value for stageId: bearer_token_value/
    );
  });
}
