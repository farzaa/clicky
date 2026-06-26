import assert from "node:assert/strict";

export function registerMagicLinkStartAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  sha256HexForTest,
}) {
  test("auth login start returns only a magic link and never stores plain email", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "Founder@Example.com" }),
      }),
      env
    );
    const body = await response.json();
    const storedValues = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.ok, true);
    assert.match(body.magicLink, /^https:\/\/api\.spider\.test\/auth\/login\/confirm\?token=/);
    assert.equal(body.sessionToken, undefined);
    assert.doesNotMatch(storedValues, /Founder@Example\.com/i);
    assert.doesNotMatch(storedValues, /founder@example\.com/i);
  });

  test("auth login start revokes previous active magic links after creating a deliverable link", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const body = await response.json();
    const statements = env.DB.executedStatements;
    const revokeIndex = statements.findIndex((statement) => (
      statement.sql.includes("UPDATE magic_links")
      && statement.sql.includes("consumed_at = unixepoch()")
      && statement.sql.includes("user_id = ?")
      && statement.sql.includes("token_hash != ?")
    ));
    const insertIndex = statements.findIndex((statement) => statement.sql.includes("INSERT INTO magic_links"));

    assert.equal(response.status, 200);
    assert.equal(body.ok, true);
    assert.notEqual(revokeIndex, -1);
    assert.notEqual(insertIndex, -1);
    assert.ok(insertIndex < revokeIndex);
    assert.equal(statements[revokeIndex].params[0], "user_test");
    assert.equal(statements[revokeIndex].params[1], statements[insertIndex].params[0]);
    assert.match(statements[revokeIndex].params[1], /^[a-f0-9]{64}$/);
  });

  test("auth login start preserves old links and consumes the new link when email delivery fails", async () => {
    const env = baseEnv({
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
      RESEND_API_KEY: "resend-test-key",
      MAGIC_LINK_FROM: "Spider <login@spider.test>",
    });
    const previousFetch = globalThis.fetch;
    let resendCalls = 0;
    globalThis.fetch = async () => {
      resendCalls += 1;
      return new Response("nope", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/auth/login/start", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-spider-device-id": "device_test",
          },
          body: JSON.stringify({ email: "founder@example.com" }),
        }),
        env
      );
      const body = await response.json();
      const statements = env.DB.executedStatements;
      const insertIndex = statements.findIndex((statement) => statement.sql.includes("INSERT INTO magic_links"));
      const rollbackIndex = statements.findIndex((statement) => (
        statement.sql.includes("UPDATE magic_links")
        && statement.sql.includes("token_hash = ?")
        && !statement.sql.includes("user_id = ?")
      ));
      const oldLinkRevokeIndex = statements.findIndex((statement) => (
        statement.sql.includes("UPDATE magic_links")
        && statement.sql.includes("user_id = ?")
        && statement.sql.includes("token_hash != ?")
      ));
      const auditIndex = statements.findIndex((statement) => statement.sql.includes("auth_magic_link_started"));

      assert.equal(response.status, 502);
      assert.equal(body.error, "Could not send magic link email.");
      assert.equal(resendCalls, 1);
      assert.notEqual(insertIndex, -1);
      assert.notEqual(rollbackIndex, -1);
      assert.ok(insertIndex < rollbackIndex);
      assert.equal(statements[rollbackIndex].params[0], statements[insertIndex].params[0]);
      assert.equal(oldLinkRevokeIndex, -1);
      assert.equal(auditIndex, -1);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("auth login start requires a device id before touching D1", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Device id is required.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login start rejects invalid device ids before touching D1", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "203.0.113.10",
          "x-spider-device-id": "bad device id!",
        },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Device id is invalid.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login start stores only a hashed device id in rate counters", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "203.0.113.10",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const storedValues = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.match(storedValues, new RegExp(`device:${sha256HexForTest("device_test")}`));
    assert.doesNotMatch(storedValues, /device_test/);
  });

  test("auth login start ignores spoofable x-forwarded-for for IP rate limits", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const spoofedIP = "198.51.100.44";
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-forwarded-for": spoofedIP,
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const storedValues = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.match(storedValues, new RegExp(`device:${sha256HexForTest("device_test")}`));
    assert.doesNotMatch(storedValues, new RegExp(`ip:${sha256HexForTest(spoofedIP)}`));
    assert.doesNotMatch(storedValues, /198\.51\.100\.44/);
  });

  test("auth login start rejects oversized Cloudflare IP headers before touching D1", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "https://api.spider.test/auth/login/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "1".repeat(129),
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "founder@example.com" }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 400);
    assert.equal(body.error, "Client IP header is invalid.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login start allows custom-scheme links only in explicit dev mode", async () => {
    const env = baseEnv({
      DEV_RETURN_MAGIC_LINK: "1",
      APP_LOGIN_CONFIRM_URL: "spider://auth/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "dev@example.com" }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.match(body.magicLink, /^spider:\/\/auth\/confirm\?token=/);
    assert.equal(body.sessionToken, undefined);
  });

  test("auth login start rejects custom-scheme email links outside dev mode before touching D1", async () => {
    const env = baseEnv({
      RESEND_API_KEY: "resend-test-key",
      MAGIC_LINK_FROM: "Spider <login@spider.test>",
      APP_LOGIN_CONFIRM_URL: "spider://auth/confirm",
    });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "203.0.113.10",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: "prod@example.com" }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 500);
    assert.equal(body.error, "APP_LOGIN_CONFIRM_URL must use https://.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("auth login start rejects invalid email shapes before touching D1", async () => {
    const invalidEmails = [
      "founder@spider",
      "usuário@example.com",
      `${"a".repeat(245)}@example.com`,
    ];

    for (const email of invalidEmails) {
      const env = baseEnv({ DEV_RETURN_MAGIC_LINK: "1" });
      const response = await fetchWorker(
        request("/auth/login/start", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ email }),
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 400);
      assert.equal(body.error, "Email is invalid.");
      assert.equal(env.DB.executedStatements.length, 0);
    }
  });

  test("auth login start rejects oversized bodies before touching D1", async () => {
    const env = baseEnv({ DEV_RETURN_MAGIC_LINK: "1" });
    const response = await fetchWorker(
      request("/auth/login/start", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "203.0.113.10",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify({ email: `${"a".repeat(5_000)}@example.com` }),
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 413);
    assert.equal(body.error, "Request body is too large.");
    assert.equal(env.DB.executedStatements.length, 0);
  });
}
