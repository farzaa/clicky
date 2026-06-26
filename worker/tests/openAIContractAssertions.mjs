import assert from "node:assert/strict";

export function registerOpenAIContractAssertions({
  test,
  baseEnv,
  capturedHeader,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
}) {
  test("vision guide sends stable OpenAI safety identifiers without user content", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAIRequestURL = "";
    let openAIHeaders = {};
    let openAIRequestBody = {};

    globalThis.fetch = async (url, init) => {
      openAIRequestURL = String(url);
      openAIHeaders = init.headers || {};
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        output_text: JSON.stringify(validGuideOutput({
          spokenText: "Use the visible Meta Ads setup as the source of truth.",
          displayText: "Use visible setup.",
          nextStep: "Stop before publishing.",
          screenState: "blocked",
          screenId: "review_publish",
          stageId: "manual_publish_boundary",
          screenConfidence: "high",
          screenEvidence: ["Publish button visible"],
          contextKind: "platform_guided_setup",
          officialRule: "Meta may review ad creative, text, targeting, and destination.",
          spiderJudgment: "Publishing is outside the current MVP; stop at the manual boundary.",
          decision: "manual_confirmation_required",
          riskLevel: "high",
          confidence: "high",
          requiresManualConfirmation: true,
          sourceType: "mixed",
          decisionMemoryUpdate: "Publishing is outside the current MVP.",
        })),
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody({
            userTranscript: "My private client ACME wants a habit app. What next?",
            platformContext: {
              candidatePlatformId: "meta_ads",
              source: "app",
              visibleURLHost: "adsmanager.facebook.com",
            },
          })),
        }),
        env
      );
      const body = await response.json();
      const safetyHeader = capturedHeader(openAIHeaders, "OpenAI-Safety-Identifier");

      assert.equal(response.status, 200);
      assert.equal(openAIRequestURL, "https://api.openai.com/v1/responses");
      assert.equal(safetyHeader, "email_hash_test");
      assert.equal(openAIRequestBody.safety_identifier, "email_hash_test");
      assert.match(openAIRequestBody.instructions, /screen-first independent paid ads instructor/);
      assert.match(openAIRequestBody.instructions, /Decision pipeline/);
      assert.match(openAIRequestBody.instructions, /Vision grounding/);
      assert.match(openAIRequestBody.instructions, /Workflow state/);
      assert.match(openAIRequestBody.instructions, /Meta best practices/);
      assert.match(openAIRequestBody.instructions, /Safety policy/);
      assert.match(openAIRequestBody.instructions, /ontology plus safety contract/);
      assert.match(openAIRequestBody.instructions, /not a visual map/);
      assert.match(openAIRequestBody.instructions, /context only/);
      assert.match(openAIRequestBody.instructions, /take the first campaign setup step/);
      assert.match(openAIRequestBody.instructions, /Guided Setup is the current MVP AHA/);
      assert.match(openAIRequestBody.instructions, /Preflight Audit is locked in the current MVP/);
      assert.match(openAIRequestBody.instructions, /72h Review is locked in the current MVP/);
      assert.doesNotMatch(openAIRequestBody.instructions, /run Preflight first|Run conservative Preflight Audit/);
      assert.match(openAIRequestBody.instructions, /Anti-loading-stuck rule/);
      assert.match(openAIRequestBody.instructions, /screenChanged=true/);
      assert.match(openAIRequestBody.instructions, /Return screenId and stageId/);
      assert.match(openAIRequestBody.instructions, /screenEvidence as short non-sensitive visual cues/);
      assert.match(openAIRequestBody.instructions, /targetConfidence is per-target/);
      assert.match(openAIRequestBody.instructions, /affordance click or select/);
      assert.match(openAIRequestBody.instructions, /scene graph/);
      assert.match(openAIRequestBody.instructions, /semanticSignature/);
      assert.match(openAIRequestBody.instructions, /expectedOutcome/);
      assert.match(openAIRequestBody.instructions, /region containing the returned coordinates/);
      assert.match(openAIRequestBody.instructions, /screenChanged=true/);
      assert.match(openAIRequestBody.instructions, /target advances the selected Ad Mission/);
      assert.match(openAIRequestBody.instructions, /point\.missionAlignment/);
      assert.match(openAIRequestBody.instructions, /point to Sales for a Sales mission, Leads for a Leads mission/);
      assert.match(openAIRequestBody.instructions, /return point coordinates for the click dot/);
      assert.match(openAIRequestBody.instructions, /displayText should be 3-8 words/);
      assert.match(openAIRequestBody.instructions, /Stop before Publish/);
      assert.match(openAIRequestBody.instructions, /Spider never spends/);
      assert.match(openAIRequestBody.instructions, /Never guarantee policy approval/);
      assert.match(openAIRequestBody.instructions, /Never call Spider playbook advice an official platform rule/);
      assert.match(openAIRequestBody.instructions, /source is absent, stale, needs review, outdated, deprecated/);
      assert.match(openAIRequestBody.instructions, /set requiresManualConfirmation to true/);
      assert.doesNotMatch(openAIRequestBody.instructions, /building their first iOS app|Product Owner|Cursor\/Codex|Xcode errors|PRD/i);
      assert.match(openAIRequestBody.input[0].content[0].text, /Active platform knowledge and playbook inventory/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Semantic screen understanding contract/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Vision-first, semantic-first/);
      assert.match(openAIRequestBody.input[0].content[0].text, /semantic_grounding/);
      assert.match(openAIRequestBody.input[0].content[0].text, /groundingRevision/);
      assert.match(openAIRequestBody.input[0].content[0].text, /semanticSignature/);
      assert.match(openAIRequestBody.input[0].content[0].text, /elements/);
      assert.match(openAIRequestBody.input[0].content[0].text, /corroboration_sources/);
      assert.match(openAIRequestBody.input[0].content[0].text, /point_auditor_contract/);
      assert.match(openAIRequestBody.input[0].content[0].text, /targetStability/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Guided session grounding context/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Screen guidance decision pipeline/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Mission-based pointing contract/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Point at the next visible safe control that advances the selected Ad Mission/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Text-only guidance is a fallback, not a replacement for the click dot/);
      assert.match(openAIRequestBody.input[0].content[0].text, /When a safe visible target is clear enough to name, return point coordinates/);
      assert.match(openAIRequestBody.input[0].content[0].text, /point\.missionAlignment/);
      assert.match(openAIRequestBody.input[0].content[0].text, /User transcript context, not visual evidence/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /semanticGrounding/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /elements/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /elementId/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /interactiveTargets/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /blockedTargets/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /groundingRevision/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /semanticSignature/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /container/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /parentLabel/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /nearestText/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /state/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /targetConfidence/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /evidence/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /affordance/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /targetStability/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /targetElementId/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /expectedOutcome/);
      assert.match(JSON.stringify(openAIRequestBody.text.format.schema), /missionAlignment/);
      assert.match(openAIRequestBody.input[0].content[0].text, /anti_loading_stuck/);
      assert.match(openAIRequestBody.input[0].content[0].text, /screen_states/);
      assert.match(openAIRequestBody.input[0].content[0].text, /official_definition/);
      assert.match(openAIRequestBody.input[0].content[0].text, /last_verified_at/);
      assert.match(openAIRequestBody.input[0].content[0].text, /Current Ad Mission snapshot/);
      assert.doesNotMatch(safetyHeader, /ACME|private|@/i);
      assert.equal(body.nextStep, "Stop before publishing.");
      assert.equal(body.screenState, "blocked");
      assert.equal(body.screenId, "review_publish");
      assert.equal(body.stageId, "manual_publish_boundary");
      assert.equal(body.screenConfidence, "high");
      assert.deepEqual(body.screenEvidence, ["Publish button visible"]);
      assert.equal(body.shouldContinuePolling, true);
      assert.equal(body.pollAfterMs, null);
      assert.equal(body.decision, "manual_confirmation_required");
      assert.equal(body.riskLevel, "high");
      assert.equal(body.sourceType, "mixed");
      assert.equal(body.officialRule, "Meta may review ad creative, text, targeting, and destination.");
      assert.equal(body.spiderJudgment, "Publishing is outside the current MVP; stop at the manual boundary.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide ignores client-provided model overrides", async () => {
    const env = baseEnv({ OPENAI_VISION_MODEL: "server-controlled-vision-model" });
    const previousFetch = globalThis.fetch;
    let openAIRequestBody = {};

    globalThis.fetch = async (_url, init) => {
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        output_text: JSON.stringify(validGuideOutput({
          spokenText: "Use the server configured model.",
          displayText: "Use server model.",
          nextStep: "Keep guidance cost controlled by the Worker.",
          contextKind: "guided_setup",
          decision: "safe_to_continue",
          riskLevel: "low",
          sourceType: "spider_playbook",
          spiderJudgment: "Model choice stays server-controlled.",
        })),
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody({
            visionModel: "client-selected-expensive-model",
          })),
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.equal(openAIRequestBody.model, "server-controlled-vision-model");
      assert.notEqual(openAIRequestBody.model, "client-selected-expensive-model");
      assert.equal(body.nextStep, "Keep guidance cost controlled by the Worker.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Realtime client secret sends stable OpenAI safety identifier without user content", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAIRequestURL = "";
    let openAIHeaders = {};
    let openAIRequestBody = {};

    globalThis.fetch = async (url, init) => {
      openAIRequestURL = String(url);
      openAIHeaders = init.headers || {};
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        client_secret: {
          value: "realtime-ephemeral-secret",
          expires_at: 1_800_000_000,
        },
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: realtimeHeaders(TEST_SESSION_TOKEN),
        }),
        env
      );
      const body = await response.json();
      const safetyHeader = capturedHeader(openAIHeaders, "OpenAI-Safety-Identifier");

      assert.equal(response.status, 200);
      assert.equal(openAIRequestURL, "https://api.openai.com/v1/realtime/client_secrets");
      assert.equal(safetyHeader, "email_hash_test");
      assert.doesNotMatch(safetyHeader, /@|private|transcript/i);
      assert.equal(openAIRequestBody.session.model, "gpt-realtime-2");
      assert.equal(body.client_secret.value, "realtime-ephemeral-secret");
      assert.equal(body.model, "gpt-realtime-2");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Realtime client secret returns only the minimal client envelope", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;

    globalThis.fetch = async () => new Response(JSON.stringify({
      value: "root-realtime-secret",
      client_secret: {
        value: "nested-realtime-secret",
        expires_at: 1_800_000_000,
        extra_secret_metadata: "do-not-proxy",
      },
      session: {
        instructions: "do-not-proxy",
        audio: { voice: "alloy" },
      },
      upstream_debug: "do-not-proxy",
    }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: realtimeHeaders(TEST_SESSION_TOKEN),
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.deepEqual(Object.keys(body).sort(), ["client_secret", "model"]);
      assert.deepEqual(Object.keys(body.client_secret).sort(), ["expires_at", "value"]);
      assert.equal(body.client_secret.value, "nested-realtime-secret");
      assert.equal(body.client_secret.expires_at, 1_800_000_000);
      assert.equal(body.model, "gpt-realtime-2");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Realtime client secret ignores client-provided model overrides", async () => {
    const env = baseEnv({ OPENAI_REALTIME_MODEL: "server-controlled-realtime-model" });
    const previousFetch = globalThis.fetch;
    let openAIRequestBody = {};

    globalThis.fetch = async (_url, init) => {
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        client_secret: {
          value: "realtime-ephemeral-secret",
          expires_at: 1_800_000_000,
        },
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: {
            ...realtimeHeaders(TEST_SESSION_TOKEN),
            "content-type": "application/json",
          },
          body: JSON.stringify({
            realtimeModel: "client-selected-expensive-realtime-model",
          }),
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.equal(openAIRequestBody.session.model, "server-controlled-realtime-model");
      assert.notEqual(openAIRequestBody.session.model, "client-selected-expensive-realtime-model");
      assert.equal(body.model, "server-controlled-realtime-model");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}

function visionGuideHeaders(sessionToken) {
  return {
    authorization: `Bearer ${sessionToken}`,
    "content-type": "application/json",
    "x-spider-device-id": "device_test",
  };
}

function realtimeHeaders(sessionToken) {
  return {
    authorization: `Bearer ${sessionToken}`,
    "x-spider-device-id": "device_test",
  };
}
