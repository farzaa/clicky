import assert from "node:assert/strict";

export function registerAIRouteGatewayAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_SESSION_TOKEN,
  unpaidUserRow,
  validVisionGuideBody,
}) {
  test("vision guide blocks unpaid users before quota, audit, or OpenAI", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: unpaidUserRow(),
      }),
    });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody()),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 402);
      assert.equal(body.error, "Active subscription required.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("Realtime client secret blocks unpaid users before quota, audit, or OpenAI", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: unpaidUserRow(),
      }),
    });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: realtimeHeaders(TEST_SESSION_TOKEN),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 402);
      assert.equal(body.error, "Active subscription required.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("vision guide fails missing OpenAI config before quota, audit, or OpenAI", async () => {
    const env = baseEnv({ OPENAI_API_KEY: "" });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody()),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 500);
      assert.equal(body.error, "OpenAI is not configured.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("Realtime client secret fails missing OpenAI config before quota, audit, or OpenAI", async () => {
    const env = baseEnv({ OPENAI_API_KEY: "" });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: realtimeHeaders(TEST_SESSION_TOKEN),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 500);
      assert.equal(body.error, "OpenAI is not configured.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("vision guide fails unsafe OpenAI model config before quota, audit, or OpenAI", async () => {
    const env = baseEnv({ OPENAI_VISION_MODEL: "bad model with spaces" });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody()),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 500);
      assert.equal(body.error, "OpenAI vision model is not configured safely.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("Realtime client secret fails unsafe OpenAI model config before quota, audit, or OpenAI", async () => {
    const env = baseEnv({ OPENAI_REALTIME_MODEL: "bad model with spaces" });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/realtime/client-secret", {
          method: "POST",
          headers: realtimeHeaders(TEST_SESSION_TOKEN),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 500);
      assert.equal(body.error, "OpenAI Realtime model is not configured safely.");
      assert.equal(openAICalls(), 0);
      assertNoQuotaAuditSideEffects(sql);
    });
  });

  test("vision guide blocks exhausted user quota before audit or OpenAI", async () => {
    const env = baseEnv({
      DAILY_VISION_LIMIT: "1",
      DB: new MockD1Database({
        usageCounts: { vision: 1 },
      }),
    });

    await withRejectedOpenAICalls(async (openAICalls) => {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: visionGuideHeaders(TEST_SESSION_TOKEN),
          body: JSON.stringify(validVisionGuideBody()),
        }),
        env
      );
      const body = await response.json();
      const sql = executedSQL(env);

      assert.equal(response.status, 429);
      assert.equal(body.error, "vision daily quota exceeded.");
      assert.equal(openAICalls(), 0);
      assert.match(sql, /INSERT INTO usage_counters/);
      assert.match(sql, /RETURNING count/);
      assert.doesNotMatch(sql, /vision_guide_requested/);
    });
  });
}

async function withRejectedOpenAICalls(assertions) {
  const previousFetch = globalThis.fetch;
  let openAICalls = 0;

  globalThis.fetch = async () => {
    openAICalls += 1;
    return new Response("unexpected", { status: 500 });
  };

  try {
    await assertions(() => openAICalls);
  } finally {
    globalThis.fetch = previousFetch;
  }
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

function executedSQL(env) {
  return env.DB.executedStatements.map((statement) => statement.sql).join("\n");
}

function assertNoQuotaAuditSideEffects(sql) {
  assert.doesNotMatch(sql, /INSERT INTO usage_counters/);
  assert.doesNotMatch(sql, /INSERT INTO rate_counters/);
  assert.doesNotMatch(sql, /INSERT INTO audit_events/);
}
