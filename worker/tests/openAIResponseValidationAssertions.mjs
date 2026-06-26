import assert from "node:assert/strict";

export function registerOpenAIResponseValidationAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validVisionGuideBody,
}) {
  test("Realtime client secret maps invalid OpenAI response envelopes to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response("not-json", {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(realtimeClientSecretRequest(request, TEST_SESSION_TOKEN), env);
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid realtime response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Realtime client secret maps missing OpenAI client secrets to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response(JSON.stringify({}), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(realtimeClientSecretRequest(request, TEST_SESSION_TOKEN), env);
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned no Realtime client secret.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Realtime client secret maps unsafe OpenAI client secrets to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response(JSON.stringify({
      client_secret: {
        value: "unsafe secret\nwith whitespace",
        expires_at: 1_800_000_000,
      },
    }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(realtimeClientSecretRequest(request, TEST_SESSION_TOKEN), env);
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid Realtime client secret.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide maps invalid OpenAI response envelopes to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response("not-json", {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid vision response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide maps invalid OpenAI guide payloads to sanitized 502", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => new Response(JSON.stringify({ output_text: "not-json" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });

    try {
      const response = await fetchWorker(
        visionGuideRequest(request, TEST_SESSION_TOKEN, validVisionGuideBody),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "OpenAI returned an invalid guide response.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}

function realtimeClientSecretRequest(request, sessionToken) {
  return request("/realtime/client-secret", {
    method: "POST",
    headers: {
      authorization: `Bearer ${sessionToken}`,
      "x-spider-device-id": "device_test",
    },
  });
}

function visionGuideRequest(request, sessionToken, validVisionGuideBody) {
  return request("/vision/guide", {
    method: "POST",
    headers: {
      authorization: `Bearer ${sessionToken}`,
      "content-type": "application/json",
      "x-spider-device-id": "device_test",
    },
    body: JSON.stringify(validVisionGuideBody()),
  });
}
