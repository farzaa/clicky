/**
 * Tests for the Clicky proxy worker.
 *
 * Uses Node's built-in test runner (no dependencies). Upstream APIs are
 * mocked by replacing globalThis.fetch, so no real keys or network needed.
 *
 * Run: npm test
 */

import { describe, test, beforeEach, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.ts";

const env = {
  ANTHROPIC_API_KEY: "test-anthropic-key",
  ELEVENLABS_API_KEY: "test-elevenlabs-key",
  ELEVENLABS_VOICE_ID: "test-voice-id",
  ASSEMBLYAI_API_KEY: "test-assemblyai-key",
};

const BASE = "https://clicky-proxy.example.workers.dev";

type Call = { url: string; init: RequestInit };
let calls: Call[];
let nextResponse: () => Response | Promise<Response>;
const realFetch = globalThis.fetch;

beforeEach(() => {
  calls = [];
  nextResponse = () => new Response("ok");
  globalThis.fetch = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    calls.push({ url: String(input), init });
    return nextResponse();
  }) as typeof fetch;
  // Keep expected error logs out of the test output
  mock.method(console, "error", () => {});
});

afterEach(() => {
  globalThis.fetch = realFetch;
  mock.restoreAll();
});

function post(path: string, body?: string) {
  return worker.fetch(new Request(BASE + path, { method: "POST", body }), env);
}

function header(call: Call, name: string) {
  return new Headers(call.init.headers).get(name);
}

describe("routing", () => {
  test("rejects non-POST requests with 405", async () => {
    const res = await worker.fetch(new Request(BASE + "/chat"), env);
    assert.equal(res.status, 405);
    assert.equal(calls.length, 0);
  });

  test("returns 404 for an unknown POST path", async () => {
    const res = await post("/nope");
    assert.equal(res.status, 404);
    assert.equal(calls.length, 0);
  });

  test("path matching is exact (no trailing slash)", async () => {
    const res = await post("/chat/");
    assert.equal(res.status, 404);
  });

  test("returns 500 JSON when an upstream call throws", async () => {
    nextResponse = () => {
      throw new TypeError("network down");
    };
    const res = await post("/chat", "{}");
    assert.equal(res.status, 500);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.match((await res.json()).error, /network down/);
  });
});

describe("POST /chat", () => {
  const body = JSON.stringify({ model: "claude-x", messages: [], stream: true });

  test("forwards the body to Anthropic with the right headers", async () => {
    await post("/chat", body);
    assert.equal(calls.length, 1);
    const [call] = calls;
    assert.equal(call.url, "https://api.anthropic.com/v1/messages");
    assert.equal(call.init.method, "POST");
    assert.equal(call.init.body, body);
    assert.equal(header(call, "x-api-key"), env.ANTHROPIC_API_KEY);
    assert.equal(header(call, "anthropic-version"), "2023-06-01");
    assert.equal(header(call, "content-type"), "application/json");
  });

  test("streams the upstream response back with no-cache", async () => {
    nextResponse = () =>
      new Response("event: message_start\n\n", {
        headers: { "content-type": "text/event-stream; charset=utf-8" },
      });
    const res = await post("/chat", body);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/event-stream; charset=utf-8");
    assert.equal(res.headers.get("cache-control"), "no-cache");
    assert.equal(await res.text(), "event: message_start\n\n");
  });

  test("defaults content-type to text/event-stream when upstream omits it", async () => {
    nextResponse = () => new Response(new Blob(["data"]).stream());
    const res = await post("/chat", body);
    assert.equal(res.headers.get("content-type"), "text/event-stream");
  });

  for (const status of [400, 401, 429, 529]) {
    test(`passes through upstream ${status} errors`, async () => {
      const err = JSON.stringify({ type: "error", error: { type: "x" } });
      nextResponse = () => new Response(err, { status });
      const res = await post("/chat", body);
      assert.equal(res.status, status);
      assert.equal(res.headers.get("content-type"), "application/json");
      assert.equal(await res.text(), err);
    });
  }
});

describe("POST /tts", () => {
  const body = JSON.stringify({ text: "hello", model_id: "eleven_flash" });

  test("forwards to ElevenLabs using the configured voice ID", async () => {
    await post("/tts", body);
    const [call] = calls;
    assert.equal(call.url, `https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`);
    assert.equal(call.init.method, "POST");
    assert.equal(call.init.body, body);
    assert.equal(header(call, "xi-api-key"), env.ELEVENLABS_API_KEY);
    assert.equal(header(call, "accept"), "audio/mpeg");
  });

  test("returns audio bytes unchanged", async () => {
    const audio = new Uint8Array([0xff, 0xfb, 0x90, 0x00]);
    nextResponse = () => new Response(audio, { headers: { "content-type": "audio/mpeg" } });
    const res = await post("/tts", body);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "audio/mpeg");
    assert.deepEqual(new Uint8Array(await res.arrayBuffer()), audio);
  });

  test("passes through upstream errors", async () => {
    nextResponse = () => new Response('{"detail":"quota_exceeded"}', { status: 401 });
    const res = await post("/tts", body);
    assert.equal(res.status, 401);
    assert.equal(await res.text(), '{"detail":"quota_exceeded"}');
  });
});

describe("POST /transcribe-token", () => {
  test("requests an 8-minute AssemblyAI streaming token with a GET", async () => {
    await post("/transcribe-token");
    const [call] = calls;
    const url = new URL(call.url);
    assert.equal(url.origin + url.pathname, "https://streaming.assemblyai.com/v3/token");
    assert.equal(url.searchParams.get("expires_in_seconds"), "480");
    assert.equal(call.init.method, "GET");
    assert.equal(header(call, "authorization"), env.ASSEMBLYAI_API_KEY);
  });

  test("returns the token JSON", async () => {
    nextResponse = () => new Response('{"token":"abc123"}');
    const res = await post("/transcribe-token");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), { token: "abc123" });
  });

  test("passes through upstream errors", async () => {
    nextResponse = () => new Response('{"error":"bad key"}', { status: 401 });
    const res = await post("/transcribe-token");
    assert.equal(res.status, 401);
  });
});

/**
 * Known gaps. These describe behavior the worker should probably have but
 * doesn't yet. They're marked `todo`, so they run and report but don't fail
 * the suite. Flip them to normal tests once the worker is fixed.
 */
describe("known gaps", () => {
  test("rejects requests that don't come from the Clicky app", { todo: "worker has no auth; anyone with the URL can spend the owner's API credits" }, async () => {
    const res = await post("/chat", "{}");
    assert.equal(res.status, 401);
  });

  test("returns 500 without calling upstream when an API key is missing", { todo: "missing secret is sent as the literal string 'undefined'" }, async () => {
    const res = await worker.fetch(
      new Request(BASE + "/chat", { method: "POST", body: "{}" }),
      { ...env, ANTHROPIC_API_KEY: undefined as unknown as string },
    );
    assert.equal(calls.length, 0);
    assert.equal(res.status, 500);
  });

  test("doesn't leak internal error details to the client", { todo: "500 body includes String(error)" }, async () => {
    nextResponse = () => {
      throw new Error("internal detail");
    };
    const res = await post("/chat", "{}");
    assert.doesNotMatch(await res.text(), /internal detail/);
  });

  test("keeps the upstream content-type on error responses", { todo: "errors are always labeled application/json, even HTML from a gateway" }, async () => {
    nextResponse = () =>
      new Response("<html>Bad Gateway</html>", { status: 502, headers: { "content-type": "text/html" } });
    const res = await post("/chat", "{}");
    assert.equal(res.headers.get("content-type"), "text/html");
  });

  test("returns 404, not 405, for a GET to an unknown path", { todo: "method is checked before the route" }, async () => {
    const res = await worker.fetch(new Request(BASE + "/nope"), env);
    assert.equal(res.status, 404);
  });
});
