import assert from "node:assert/strict";

export function registerHttpSurfaceAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
}) {
  test("unknown routes return JSON without wildcard CORS or cache", async () => {
    const response = await fetchWorker(request("/missing"));

    assert.equal(response.status, 404);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    assert.match(response.headers.get("content-type") || "", /^application\/json/);
  });

  test("account return page is static and locked down", async () => {
    const response = await fetchWorker(
      request("/account", {
        headers: { accept: "text/html" },
      })
    );
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") || "", /^text\/html/);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    assert.match(response.headers.get("content-security-policy") || "", /default-src 'none'/);
    assert.match(response.headers.get("content-security-policy") || "", /script-src 'none'/);
    assert.doesNotMatch(html, /<script/i);
    assert.match(html, /Return to Spider/);
  });

  test("CORS stays disabled unless the origin is explicitly allowed", async () => {
    const response = await fetchWorker(
      request("/auth/login/status", {
        method: "OPTIONS",
        headers: { origin: "https://attacker.test" },
      })
    );

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  });

  test("CORS echoes an exact configured web origin", async () => {
    const response = await fetchWorker(
      request("/auth/login/status", {
        method: "OPTIONS",
        headers: { origin: "https://app.spider.test" },
      }),
      baseEnv({
        ALLOWED_WEB_ORIGINS: "https://app.spider.test,https://admin.spider.test",
      })
    );

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), "https://app.spider.test");
    assert.equal(response.headers.get("vary"), "Origin");
  });

  test("CORS rejects wildcard and insecure configured origins at runtime", async () => {
    const response = await fetchWorker(
      request("/auth/login/status", {
        method: "OPTIONS",
        headers: { origin: "https://app.spider.test" },
      }),
      baseEnv({
        ALLOWED_WEB_ORIGINS: "*,http://app.spider.test,https://app.spider.test/path",
      })
    );

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  });

  test("CORS normalizes exact HTTPS origins before matching", async () => {
    const response = await fetchWorker(
      request("/auth/login/status", {
        method: "OPTIONS",
        headers: { origin: "https://app.spider.test" },
      }),
      baseEnv({
        ALLOWED_WEB_ORIGINS: " https://app.spider.test/ ",
      })
    );

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), "https://app.spider.test");
  });
}
