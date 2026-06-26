import assert from "node:assert/strict";

export function registerAIRouteSecurityAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validVisionGuideBody,
}) {
  test("AI routes reject missing sessions before parsing screenshot payloads", async () => {
    const response = await fetchWorker(
      request("/vision/guide", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "not-json",
      })
    );
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Missing session token.");
  });

  test("vision guide rejects invalid screenshots before calling OpenAI", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAICalls = 0;
    globalThis.fetch = async () => {
      openAICalls += 1;
      return new Response("unexpected", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "content-type": "application/json",
            "x-spider-device-id": "device_test",
          },
          body: JSON.stringify({
            userTranscript: "What should I do now?",
            screenshots: [
              {
                label: "Main display",
                imageBase64: "PHN2Zz48L3N2Zz4=",
                mimeType: "image/svg+xml",
                isCursorScreen: true,
                displayWidthInPoints: 1440,
                displayHeightInPoints: 900,
                screenshotWidthInPixels: 2880,
                screenshotHeightInPixels: 1800,
              },
            ],
          }),
        }),
        env
      );
      const body = await response.json();
      const sql = env.DB.executedStatements.map((statement) => statement.sql).join("\n");

      assert.equal(response.status, 400);
      assert.equal(body.error, "Screenshot 1 has an unsupported image type.");
      assert.equal(openAICalls, 0);
      assert.doesNotMatch(sql, /INSERT INTO usage_counters/);
      assert.doesNotMatch(sql, /INSERT INTO audit_events/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide rejects sensitive guided session context before OpenAI", async () => {
    const previousFetch = globalThis.fetch;
    let openAICalled = false;
    globalThis.fetch = async () => {
      openAICalled = true;
      return new Response("{}");
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "content-type": "application/json",
            "x-spider-device-id": "device_test",
          },
          body: JSON.stringify(validVisionGuideBody({
            guidedSessionContext: {
              currentScreenSignature: "main:2880x1800:hash",
              previousScreenSignature: "main:2880x1800:oldhash",
              screenChanged: true,
              previousAcceptedTarget: {
                label: "Security code 123456",
                missionAlignment: "Previous safe setup step",
                screenId: "objective_selection",
                stageId: "choose_objective",
              },
            },
          })),
        })
      );
      const body = await response.json();

      assert.equal(response.status, 400);
      assert.equal(body.error, "Previous target label is invalid.");
      assert.equal(openAICalled, false);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}
