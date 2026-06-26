import assert from "node:assert/strict";

export function registerVisionGuidePointSafetyAssertions({
  test,
  baseEnv,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  validVisionGuideBody,
  guidePoint,
  testElementId,
  semanticGroundingElement,
  semanticGroundingForPointLabels,
  semanticGroundingTarget,
}) {
  test("vision guide accepts safe points only on high-confidence recognized screens", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.deepEqual(body.point, {
      x: 120,
      y: 140,
      label: "Objective option",
      screenNumber: 1,
      missionAlignment: "Matches mission objective",
      targetElementId: testElementId("Objective option"),
      expectedOutcome: "item_selected",
    });
  });

  test("vision guide rejects points without a safe semantic grounding target", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        groundingRevision: "test-grounding-revision",
        semanticSignature: "model-provided-signature",
        elements: [],
        visibleConcepts: ["Objective options visible"],
        interactiveTargets: [],
        blockedTargets: [],
        uncertainty: [],
      },
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points when target confidence is not high", async () => {
    for (const targetConfidence of ["low", "medium"]) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          interactiveTargets: [
            semanticGroundingTarget("Objective option", { targetConfidence }),
          ],
        },
        point: guidePoint({
          missionAlignment: "Matches selected mission",
        }),
      }));
      const body = await response.json();

      assert.equal(response.status, 502, `${targetConfidence} target confidence should be rejected`);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide rejects points with non-click affordances", async () => {
    for (const affordance of ["type", "read", "scroll", "wait", "confirm_manually"]) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          interactiveTargets: [
            semanticGroundingTarget("Objective option", { affordance }),
          ],
        },
        point: guidePoint({
          missionAlignment: "Matches selected mission",
        }),
      }));
      const body = await response.json();

      assert.equal(response.status, 502, `${affordance} affordance should be rejected`);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide rejects points outside the matched target region", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels([]),
        interactiveTargets: [
          semanticGroundingTarget("Objective option", {
            region: {
              x: 600,
              y: 700,
              width: 80,
              height: 32,
            },
          }),
        ],
      },
      point: guidePoint({
        missionAlignment: "Matches selected mission",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points inside blocked target regions", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        blockedTargets: [
          semanticGroundingTarget("Publish", {
            risk: "restricted",
            semanticIntent: "Publish campaign",
            affordance: "confirm_manually",
            region: {
              x: 110,
              y: 130,
              width: 90,
              height: 40,
            },
          }),
        ],
      },
      point: guidePoint({
        missionAlignment: "Matches selected mission",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects action-risk boundary targets even when target risk claims low", async () => {
    for (const semanticIntent of ["Publish campaign", "Update billing", "Increase budget"]) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          elements: [
            semanticGroundingElement("Continue"),
          ],
          interactiveTargets: [
            semanticGroundingTarget("Continue", {
              risk: "low",
              semanticIntent,
              affordance: "click",
            }),
          ],
        },
        point: guidePoint({
          label: "Continue",
          missionAlignment: "Matches selected mission",
        }),
      }));
      const body = await response.json();

      assert.equal(response.status, 502, `${semanticIntent} boundary should be rejected`);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide rejects main-content points while a modal context is visible", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        blockedTargets: [
          semanticGroundingTarget("Confirm", {
            role: "modal",
            container: "modal",
            risk: "medium",
            semanticIntent: "Confirmation modal",
            affordance: "confirm_manually",
            region: {
              x: 400,
              y: 300,
              width: 320,
              height: 180,
            },
          }),
        ],
      },
      point: guidePoint({
        missionAlignment: "Matches selected mission",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects stale targets after a screen change", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(
      validGuideOutput({
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          interactiveTargets: [
            semanticGroundingTarget("Objective option", { targetStability: "stale" }),
          ],
        },
        point: guidePoint({
          missionAlignment: "Matches selected mission",
        }),
      }),
      baseEnv(),
      validVisionGuideBody({
        guidedSessionContext: {
          currentScreenSignature: "screen:b",
          previousScreenSignature: "screen:a",
          screenChanged: true,
          previousAcceptedTarget: {
            label: "Objective option",
            missionAlignment: "Previous selected mission",
            screenId: "objective_selection",
            stageId: "choose_objective",
          },
        },
      })
    );
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects sensitive nearest text and target evidence", async () => {
    const sensitiveTargetCases = [
      semanticGroundingTarget("Objective option", { nearestText: ["Security code 123456"] }),
      semanticGroundingTarget("Objective option", { evidence: ["Card 4242 4242 4242 4242 visible"] }),
    ];

    for (const target of sensitiveTargetCases) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        semanticGrounding: {
          ...semanticGroundingForPointLabels([]),
          interactiveTargets: [target],
        },
      }));
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    }
  });

  test("vision guide rejects points when linked scene graph element is occluded", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        elements: [
          semanticGroundingElement("Objective option", { occluded: true }),
        ],
      },
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points when elementId is missing", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        elements: [],
      },
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points when linked element confidence is low", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        elements: [
          semanticGroundingElement("Objective option", { confidence: "medium" }),
        ],
      },
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points when target and element regions are incompatible", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        elements: [
          semanticGroundingElement("Objective option", {
            region: {
              x: 700,
              y: 800,
              width: 80,
              height: 32,
            },
          }),
        ],
      },
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide derives stable semantic signatures from meaningful UI structure", async () => {
    const firstResponse = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        groundingRevision: "revision-a",
        visibleConcepts: ["Objective options visible"],
      },
      point: null,
    }));
    const secondResponse = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: {
        ...semanticGroundingForPointLabels(["Objective option"]),
        groundingRevision: "revision-b",
        visibleConcepts: ["Objective options visible", "Tiny animation frame"],
      },
      point: null,
    }));
    const firstBody = await firstResponse.json();
    const secondBody = await secondResponse.json();

    assert.equal(firstResponse.status, 200);
    assert.equal(secondResponse.status, 200);
    assert.equal(firstBody.semanticGrounding.semanticSignature, secondBody.semanticGrounding.semanticSignature);
  });

  test("vision guide changes semantic signature when safe targets change", async () => {
    const firstResponse = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: semanticGroundingForPointLabels(["Objective option"]),
      point: null,
    }));
    const secondResponse = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      semanticGrounding: semanticGroundingForPointLabels(["Different objective"]),
      point: null,
    }));
    const firstBody = await firstResponse.json();
    const secondBody = await secondResponse.json();

    assert.equal(firstResponse.status, 200);
    assert.equal(secondResponse.status, 200);
    assert.notEqual(firstBody.semanticGrounding.semanticSignature, secondBody.semanticGrounding.semanticSignature);
  });

  test("vision guide accepts safe high-confidence points on setup screens", async () => {
    const safeSetupCases = [
      ["objective_selection", "choose_objective", "Objective option"],
      ["audience_and_placements", "audience_setup", "Audience field"],
      ["creative_and_destination", "creative_setup", "Creative preview"],
      ["tracking_conversion_event", "tracking_setup", "Conversion event"],
    ];

    for (const [screenId, stageId, label] of safeSetupCases) {
      const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
        screenState: "recognized",
        screenId,
        stageId,
        screenConfidence: "high",
        screenEvidence: [`${screenId} visible`],
        confidence: "high",
        point: guidePoint({
          label,
          targetElementId: testElementId(label),
          missionAlignment: "Matches selected mission",
          expectedOutcome: label === "Objective option" ? "item_selected" : "state_changed",
        }),
      }));
      const body = await response.json();

      assert.equal(response.status, 200, `${screenId}/${stageId} should allow safe point`);
      assert.deepEqual(body.point, {
        x: 120,
        y: 140,
        label,
        screenNumber: 1,
        missionAlignment: "Matches selected mission",
        targetElementId: testElementId(label),
        expectedOutcome: label === "Objective option" ? "item_selected" : "state_changed",
      });
    }
  });

  test("vision guide rejects sensitive point mission alignment", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      point: guidePoint({
        missionAlignment: "Email user@example.com visible",
      }),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });

  test("vision guide rejects points on medium-confidence recognized screens", async () => {
    const response = await fetchVisionGuideWithMockedGuideOutput(validGuideOutput({
      screenConfidence: "medium",
      confidence: "medium",
      point: guidePoint(),
    }));
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.equal(body.error, "OpenAI returned an invalid guide response.");
  });
}
