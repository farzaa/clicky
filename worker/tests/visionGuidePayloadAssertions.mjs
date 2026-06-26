import assert from "node:assert/strict";

export function registerVisionGuidePayloadAssertions({
  test,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  guidePoint,
  testElementId,
}) {
  test("vision guide accepts loading only with valid screenState and no point", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "",
      displayText: "Still loading.",
      nextStep: "Wait for the platform to finish loading.",
      screenState: "loading",
      screenId: "loading_screen",
      stageId: "loading",
      screenConfidence: "low",
      screenEvidence: ["Spinner visible"],
      contextKind: "platform_guided_setup",
      decision: "needs_more_signal",
      riskLevel: "low",
      confidence: "low",
      shouldContinuePolling: true,
      pollAfterMs: 2500,
      point: null,
    }));
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.screenState, "loading");
    assert.equal(body.screenId, "loading_screen");
    assert.equal(body.stageId, "loading");
    assert.equal(body.screenConfidence, "low");
    assert.deepEqual(body.screenEvidence, ["Spinner visible"]);
    assert.equal(body.shouldContinuePolling, true);
    assert.equal(body.pollAfterMs, 2500);
    assert.equal(body.point, null);
  });

  test("vision guide accepts unknown only when it asks for confirmation and returns no point", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "Não reconheci ainda. Confirme qual tela está aberta.",
      displayText: "Não reconheci ainda",
      nextStep: "Confirme qual tela do Meta Ads está aberta.",
      screenState: "unknown",
      screenId: "unknown_screen",
      stageId: "unknown_stage",
      screenConfidence: "low",
      screenEvidence: ["Screen text unclear"],
      contextKind: "unclear",
      decision: "needs_more_signal",
      riskLevel: "medium",
      confidence: "low",
      requiresManualConfirmation: true,
      point: null,
    }));
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.screenState, "unknown");
    assert.equal(body.screenId, "unknown_screen");
    assert.equal(body.stageId, "unknown_stage");
    assert.equal(body.requiresManualConfirmation, true);
    assert.equal(body.point, null);
  });

  test("vision guide rejects invalid screenState values", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      screenState: "confident_guess",
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects sensitive values in screen evidence", async () => {
    const sensitiveEvidenceCases = [
      "Email user@example.com visible",
      "Security code 123456 visible",
      "Card 4242 4242 4242 4242 visible",
      "Bearer token visible",
    ];

    for (const evidence of sensitiveEvidenceCases) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        screenEvidence: [evidence],
      }));
      const body = await response.json();

      assert.equal(response.status, 502, `${evidence} should be rejected`);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide rejects sensitive values in semantic grounding", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        groundingRevision: "test-grounding-revision",
        semanticSignature: "model-provided-signature",
        elements: [],
        visibleConcepts: ["Email user@example.com visible"],
        interactiveTargets: [],
        blockedTargets: [],
        uncertainty: [],
      },
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects unknown screens without manual confirmation", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "I cannot recognize this yet.",
      displayText: "Não reconheci ainda",
      nextStep: "Confirm which ads platform screen is open.",
      screenState: "unknown",
      screenId: "unknown_screen",
      stageId: "unknown_stage",
      screenConfidence: "low",
      contextKind: "unclear",
      decision: "needs_more_signal",
      riskLevel: "medium",
      confidence: "low",
      requiresManualConfirmation: false,
      point: null,
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects loading screens with point coordinates", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "",
      displayText: "Still loading.",
      nextStep: "Wait for the platform to finish loading.",
      screenState: "loading",
      screenId: "loading_screen",
      stageId: "loading",
      screenConfidence: "low",
      screenEvidence: ["Skeleton visible"],
      contextKind: "platform_guided_setup",
      decision: "needs_more_signal",
      riskLevel: "low",
      confidence: "low",
      point: guidePoint({
        label: "Stale point",
        missionAlignment: "Not mission aligned",
        targetElementId: testElementId("Stale point"),
        expectedOutcome: "unknown",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects unknown screens with point coordinates", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "I cannot recognize this yet.",
      displayText: "Não reconheci ainda",
      nextStep: "Confirm which ads platform screen is open.",
      screenState: "unknown",
      screenId: "unknown_screen",
      stageId: "unknown_stage",
      screenConfidence: "low",
      contextKind: "unclear",
      decision: "needs_more_signal",
      riskLevel: "medium",
      confidence: "low",
      point: guidePoint({
        label: "Guess",
        missionAlignment: "Not visually confirmed",
        targetElementId: testElementId("Guess"),
        expectedOutcome: "unknown",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });
}
