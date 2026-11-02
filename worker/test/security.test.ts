import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import worker from "../src/index.ts";

const baseURL = "https://clicky-proxy.example.workers.dev";
const expectedToken = "test-proxy-token";
const env = {
  ANTHROPIC_API_KEY: "test-anthropic-key",
  ELEVENLABS_API_KEY: "test-elevenlabs-key",
  ELEVENLABS_VOICE_ID: "test-voice-id",
  ASSEMBLYAI_API_KEY: "test-assemblyai-key",
  CLICKY_PROXY_TOKEN: expectedToken
};

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("fails closed when the Worker token is not configured", async () => {
  let upstreamWasCalled = false;
  globalThis.fetch = (async () => {
    upstreamWasCalled = true;
    return new Response("unexpected");
  }) as typeof fetch;

  const response = await worker.fetch(
    new Request(`${baseURL}/chat`, { method: "POST", body: "{}" }),
    { ...env, CLICKY_PROXY_TOKEN: undefined }
  );

  assert.equal(response.status, 503);
  assert.equal(upstreamWasCalled, false);
});

test("rejects requests with no bearer token", async () => {
  let upstreamWasCalled = false;
  globalThis.fetch = (async () => {
    upstreamWasCalled = true;
    return new Response("unexpected");
  }) as typeof fetch;

  const response = await worker.fetch(
    new Request(`${baseURL}/chat`, { method: "POST", body: "{}" }),
    env
  );

  assert.equal(response.status, 401);
  assert.equal(response.headers.get("www-authenticate"), "Bearer");
  assert.equal(upstreamWasCalled, false);
});

test("requires bearer authorization on every provider route", async () => {
  const protectedRoutes = ["/chat", "/tts", "/transcribe-token"];

  for (const route of protectedRoutes) {
    const response = await worker.fetch(
      new Request(`${baseURL}${route}`, { method: "POST", body: "{}" }),
      env
    );

    assert.equal(response.status, 401, `${route} should require a token`);
  }
});

test("rejects an incorrect bearer token", async () => {
  const response = await worker.fetch(
    new Request(`${baseURL}/chat`, {
      method: "POST",
      body: "{}",
      headers: { authorization: "Bearer wrong-token" }
    }),
    env
  );

  assert.equal(response.status, 401);
});

test("accepts the configured bearer token and forwards the request", async () => {
  let upstreamURL = "";
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    upstreamURL = String(input);
    return new Response("ok", { headers: { "content-type": "application/json" } });
  }) as typeof fetch;

  const response = await worker.fetch(
    new Request(`${baseURL}/chat`, {
      method: "POST",
      body: "{}",
      headers: { authorization: `Bearer ${expectedToken}` }
    }),
    env
  );

  assert.equal(response.status, 200);
  assert.equal(upstreamURL, "https://api.anthropic.com/v1/messages");
  assert.equal(await response.text(), "ok");
});

test("fails before contacting a provider when its API key is missing", async () => {
  let upstreamWasCalled = false;
  globalThis.fetch = (async () => {
    upstreamWasCalled = true;
    return new Response("unexpected");
  }) as typeof fetch;

  const response = await worker.fetch(
    new Request(`${baseURL}/chat`, {
      method: "POST",
      body: "{}",
      headers: { authorization: `Bearer ${expectedToken}` }
    }),
    { ...env, ANTHROPIC_API_KEY: undefined }
  );

  assert.equal(response.status, 503);
  assert.equal(upstreamWasCalled, false);
});

test("does not expose unexpected upstream error details to the client", async () => {
  const originalConsoleError = console.error;
  console.error = () => {};
  globalThis.fetch = (async () => {
    throw new Error("sensitive internal detail");
  }) as typeof fetch;

  try {
    const response = await worker.fetch(
      new Request(`${baseURL}/chat`, {
        method: "POST",
        body: "{}",
        headers: { authorization: `Bearer ${expectedToken}` }
      }),
      env
    );

    assert.equal(response.status, 500);
    assert.doesNotMatch(await response.text(), /sensitive internal detail/);
  } finally {
    console.error = originalConsoleError;
  }
});
