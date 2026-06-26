import assert from "node:assert/strict";

export function registerMagicLinkConfirmBridgeAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_MAGIC_LINK_TOKEN,
  sha256HexForTest,
}) {
  test("auth login confirm requires a device id before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: { accept: "application/json" },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Device id is required.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login confirm rejects missing tokens before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request("/auth/login/confirm", {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Missing token.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login confirm rejects malformed tokens before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request("/auth/login/confirm?token=not-a-real-token", {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Magic link token is invalid.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login confirm rejects extra query parameters before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}&utm_source=email`, {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Magic link URL is invalid.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("magic-link browser bridge rejects malformed tokens before touching D1", async () => {
    const env = baseEnv({
      APP_LOGIN_DEEP_LINK_URL: "spider://auth/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/confirm?token=not-a-real-token", {
        headers: { accept: "text/html" },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Magic link token is invalid.");
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("magic-link browser bridge rejects extra query parameters before touching D1", async () => {
    const env = baseEnv({
      APP_LOGIN_DEEP_LINK_URL: "spider://auth/confirm",
    });
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}&next=https://evil.test`, {
        headers: { accept: "text/html" },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Magic link URL is invalid.");
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login confirm rejects invalid device ids before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "bad/device",
        },
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Device id is invalid.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login confirm blocks exhausted device rate limit before magic-link lookup", async () => {
    const env = baseEnv({
      DAILY_DEVICE_AUTH_CONFIRM_LIMIT: "1",
      DB: new MockD1Database({
        rateCounts: { auth_confirm: 1 },
      }),
    });
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();
    const sql = env.DB.executedStatements.map((statement) => statement.sql).join("\n");

    assert.equal(response.status, 429);
    assert.equal(body.error, "auth_confirm rate limit exceeded.");
    assert.match(sql, /INSERT INTO rate_counters/);
    assert.doesNotMatch(sql, /FROM magic_links/);
    assert.doesNotMatch(sql, /UPDATE magic_links/);
    assert.doesNotMatch(sql, /INSERT INTO sessions/);
    assert.doesNotMatch(sql, /auth_session_created/);
  });

  test("magic-link browser bridge blocks exhausted IP rate limit before magic-link lookup", async () => {
    const env = baseEnv({
      APP_LOGIN_DEEP_LINK_URL: "spider://auth/confirm",
      DAILY_IP_AUTH_CONFIRM_LIMIT: "1",
      DB: new MockD1Database({
        rateCounts: { auth_confirm: 1 },
      }),
    });
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: {
          accept: "text/html",
          "cf-connecting-ip": "203.0.113.20",
        },
      }),
      env
    );
    const body = await response.json();
    const sql = env.DB.executedStatements.map((statement) => statement.sql).join("\n");

    assert.equal(response.status, 429);
    assert.equal(body.error, "auth_confirm rate limit exceeded.");
    assert.match(sql, /INSERT INTO rate_counters/);
    assert.doesNotMatch(sql, /FROM magic_links/);
    assert.doesNotMatch(sql, /UPDATE magic_links/);
    assert.doesNotMatch(sql, /INSERT INTO sessions/);
  });

  test("auth login confirm stores only a device hash with the session", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: {
          accept: "application/json",
          "x-spider-device-id": "device_test",
        },
      }),
      env
    );
    const body = await response.json();
    const statements = env.DB.executedStatements;
    const sessionInsert = statements.find((statement) => statement.sql.includes("INSERT INTO sessions"));

    assert.equal(response.status, 200);
    assert.equal(typeof body.sessionToken, "string");
    assert.match(sessionInsert.sql, /device_hash/);
    assert.equal(sessionInsert.params[3], sha256HexForTest("device_test"));
    assert.doesNotMatch(JSON.stringify(sessionInsert), /device_test/);
  });

  test("magic-link browser bridge never returns a long-lived session token", async () => {
    const response = await fetchWorker(
      request(`/auth/login/confirm?token=${TEST_MAGIC_LINK_TOKEN}`, {
        headers: { accept: "text/html" },
      }),
      baseEnv({
        APP_LOGIN_DEEP_LINK_URL: "spider://auth/confirm",
      })
    );
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.match(response.headers.get("content-security-policy") || "", /default-src 'none'/);
    assert.match(response.headers.get("content-security-policy") || "", /script-src 'none'/);
    assert.match(response.headers.get("content-security-policy") || "", /frame-ancestors 'none'/);
    assert.equal(response.headers.get("referrer-policy"), "no-referrer");
    assert.match(html, /spider:\/\/auth\/confirm\?token=/);
    assert.doesNotMatch(html, /sessionToken/i);
    assert.doesNotMatch(html, /<script/i);
  });
}
