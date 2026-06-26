import assert from "node:assert/strict";

export function registerVisionGuidePromptResponseAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
  guidePoint,
  testElementId,
  semanticGroundingElement,
  semanticGroundingForPointLabels,
  semanticGroundingTarget,
}) {
  test("vision guide carries mission-aligned point metadata for selected objective", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAIRequestBody = {};

    globalThis.fetch = async (_url, init) => {
      openAIRequestBody = JSON.parse(init.body);
      return openAIGuideResponse(validGuideOutput({
        spokenText: "Choose Leads because the mission needs qualified contacts.",
        displayText: "Choose Leads.",
        nextStep: "Select Leads as the objective.",
        screenState: "recognized",
        screenId: "objective_selection",
        stageId: "choose_objective",
        screenConfidence: "high",
        screenEvidence: ["Objective options visible"],
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          elements: [
            semanticGroundingElement("Leads", {
              id: testElementId("Leads"),
              region: {
                x: 400,
                y: 340,
                width: 90,
                height: 48,
              },
            }),
          ],
          interactiveTargets: [
            semanticGroundingTarget("Leads", {
              semanticIntent: "Leads objective",
              region: {
                x: 400,
                y: 340,
                width: 90,
                height: 48,
              },
            }),
          ],
        },
        point: guidePoint({
          x: 420,
          y: 360,
          label: "Leads",
          missionAlignment: "Matches Leads mission objective",
          targetElementId: testElementId("Leads"),
        }),
      }));
    };

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody({
          adMissionSnapshot: {
            offer: "Consulting sprint",
            targetAudience: "B2B founders",
            country: "United States",
            language: "English",
            businessObjective: "Get qualified leads",
            recommendedChannel: "Meta Ads",
            campaignDirection: {
              recommendedObjective: "Leads",
              conversionEventSuggestion: "Lead",
              audienceStartingPoint: "Start broad with B2B founder cues.",
              creativeAngle: "Problem-aware lead magnet.",
            },
          },
        })),
        env
      );
      const body = await response.json();
      const promptText = openAIRequestBody.input[0].content[0].text;

      assert.equal(response.status, 200);
      assert.match(promptText, /"recommendedObjective":"Leads"/);
      assert.match(promptText, /Point exactly to the visible objective matching campaignDirection\.recommendedObjective/);
      assert.deepEqual(body.point, {
        x: 420,
        y: 360,
        label: "Leads",
        screenNumber: 1,
        missionAlignment: "Matches Leads mission objective",
        targetElementId: testElementId("Leads"),
        expectedOutcome: "item_selected",
      });
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide rejects decisions outside the paid ads contract", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      decision: "auto_publish",
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide requires manual confirmation for spend or publishing boundaries", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      decision: "manual_confirmation_required",
      riskLevel: "critical",
      requiresManualConfirmation: false,
      spiderJudgment: "Publishing or budget actions require the user to act manually.",
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide maps oversized OpenAI guide payloads to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      spokenText: "Keep it short.",
      displayText: "x".repeat(2_401),
      nextStep: "Stop before publishing.",
      contextKind: "platform_guided_setup",
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide maps invalid OpenAI guide artifacts to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      spokenText: "Use the prompt on screen.",
      displayText: "Use the prompt on screen.",
      nextStep: "Generate a safer creative variation.",
      contextKind: "creative_review",
      artifact: {
        kind: "unsafeKind",
        title: "Bad artifact",
        markdown: "Do not persist this.",
      },
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide maps invalid OpenAI Ad Mission updates to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      spokenText: "Keep the Ad Mission narrow.",
      displayText: "Keep the Ad Mission narrow.",
      nextStep: "Turn the offer into one testable Meta Ads campaign plan.",
      contextKind: "ad_mission",
      adMissionUpdate: "not-an-object",
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide drops invalid OpenAI point coordinates without losing guidance", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => openAIGuideResponse(validGuideOutput({
      spokenText: "Use the visible error as the next debugging target.",
      displayText: "Check visible error.",
      nextStep: "Review the visible Meta Ads warning before continuing.",
      contextKind: "meta_ads_manager",
      point: {
        x: 999_999,
        y: 100,
        label: "Out of bounds",
        screenNumber: 1,
        missionAlignment: "Matches mission objective",
        targetElementId: testElementId("Out of bounds"),
        expectedOutcome: "unknown",
      },
    }));

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody()),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.equal(body.nextStep, "Review the visible Meta Ads warning before continuing.");
      assert.equal(body.point, null);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}

function openAIGuideResponse(guideOutput) {
  return new Response(JSON.stringify({
    output_text: JSON.stringify(guideOutput),
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function visionGuideRequest(request, sessionToken, body) {
  return request("/vision/guide", {
    method: "POST",
    headers: {
      authorization: `Bearer ${sessionToken}`,
      "content-type": "application/json",
      "x-spider-device-id": "device_test",
    },
    body: JSON.stringify(body),
  });
}
