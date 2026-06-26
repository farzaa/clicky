import assert from "node:assert/strict";

export function registerAuthStatusAccessAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_SESSION_TOKEN,
  paidUserRow,
  sha256HexForTest,
  validVisionGuideBody,
}) {
  test("auth status missing bearer returns a sanitized 401", async () => {
    const response = await fetchWorker(request("/auth/login/status"));
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Missing session token.");
  });

  test("auth status rejects malformed bearer tokens before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: "Bearer not-a-real-session-token",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Invalid or expired session.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth status requires a device id before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Device id is required.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth status derives access from Stripe subscription over stale active entitlement", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          entitlement_status: "active",
          subscription_status: "past_due",
        }),
      }),
    });
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.authenticated, true);
    assert.equal(body.entitlementStatus, "canceled");
  });

  test("auth status ends canceled access after the paid period expires", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          entitlement_status: "active",
          subscription_status: "canceled",
          subscription_current_period_end: Math.floor(Date.now() / 1000) - 60,
        }),
      }),
    });
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.authenticated, true);
    assert.equal(body.entitlementStatus, "canceled");
  });

  test("vision guide blocks stale active entitlement when Stripe subscription is past due", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          entitlement_status: "active",
          subscription_status: "past_due",
        }),
      }),
    });
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
          body: JSON.stringify(validVisionGuideBody()),
        }),
        env
      );
      const body = await response.json();
      const sql = env.DB.executedStatements.map((statement) => statement.sql).join("\n");

      assert.equal(response.status, 402);
      assert.equal(body.error, "Active subscription required.");
      assert.equal(openAICalls, 0);
      assert.doesNotMatch(sql, /INSERT INTO usage_counters/);
      assert.doesNotMatch(sql, /INSERT INTO rate_counters/);
      assert.doesNotMatch(sql, /INSERT INTO audit_events/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("auth status rejects a device-bound session from a different device", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        sessionDeviceHash: sha256HexForTest("device_a"),
      }),
    });
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "x-spider-device-id": "device_b",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Invalid or expired session.");
  });

  test("auth status rejects legacy sessions without a device hash", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        sessionDeviceHash: null,
      }),
    });
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Invalid or expired session.");
  });

  test("auth status accepts a device-bound session from the same device", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        sessionDeviceHash: sha256HexForTest("device_a"),
      }),
    });
    const response = await fetchWorker(
      request("/auth/login/status", {
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "x-spider-device-id": "device_a",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.authenticated, true);
    assert.equal(body.entitlementStatus, "active");
  });
}
