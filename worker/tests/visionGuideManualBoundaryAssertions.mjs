import assert from "node:assert/strict";

export function registerVisionGuideManualBoundaryAssertions({
  test,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  guidePoint,
  testElementId,
}) {
  test("vision guide rejects unsafe point labels even on safe screens", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      point: guidePoint({
        label: "Publish campaign",
        missionAlignment: "Matches mission objective",
        targetElementId: testElementId("Publish campaign"),
        expectedOutcome: "unknown",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects restricted screens when returned as recognized guidance", async () => {
    const restrictedCases = [
      ["login", "authenticate", "Password field"],
      ["two_factor_auth_checkpoint", "authenticate", "Verification code"],
      ["budget_and_schedule", "budget_boundary", "Daily budget"],
      ["review_publish", "manual_publish_boundary", "Publish campaign"],
      ["billing_payment", "billing_boundary", "Payment method"],
      ["account_quality_policy", "policy_boundary", "Appeal button"],
      ["reporting_delivery", "72h_review", "Delivery table"],
    ];

    for (const [screenId, stageId, label] of restrictedCases) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        screenState: "recognized",
        screenId,
        stageId,
        screenConfidence: "high",
        screenEvidence: [`${screenId} visible`],
        decision: "safe_to_continue",
        riskLevel: "low",
        confidence: "high",
        requiresManualConfirmation: false,
        point: guidePoint({
          label,
          missionAlignment: "Matches selected mission",
          targetElementId: testElementId(label),
          expectedOutcome: "unknown",
        }),
      }));
      const body = await response.json();

      assert.equal(response.status, 502, `${screenId}/${stageId} should be blocked`);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide accepts restricted screens only as blocked manual boundaries without points", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "Stop here. Billing is outside Spider.",
      displayText: "Manual billing step.",
      nextStep: "Handle billing directly in Meta.",
      screenState: "blocked",
      screenId: "billing_payment",
      stageId: "billing_boundary",
      screenConfidence: "high",
      screenEvidence: ["Payment settings visible"],
      contextKind: "platform_guided_setup",
      decision: "manual_confirmation_required",
      riskLevel: "critical",
      confidence: "high",
      requiresManualConfirmation: true,
      point: null,
    }));
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.screenState, "blocked");
    assert.equal(body.screenId, "billing_payment");
    assert.equal(body.stageId, "billing_boundary");
    assert.equal(body.requiresManualConfirmation, true);
    assert.equal(body.point, null);
  });

  test("vision guide requires manual confirmation for blocked screens", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      spokenText: "This is a manual boundary.",
      displayText: "Manual boundary.",
      nextStep: "Stop and review this manually.",
      screenState: "blocked",
      screenId: "billing_payment",
      stageId: "billing_boundary",
      screenConfidence: "high",
      screenEvidence: ["Payment settings visible"],
      contextKind: "platform_guided_setup",
      decision: "manual_confirmation_required",
      riskLevel: "critical",
      confidence: "high",
      requiresManualConfirmation: false,
      shouldContinuePolling: true,
      point: null,
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });
}
