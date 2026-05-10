// Dot inference proxy.
//
// Stateless: verifies the bearer token with vibe-id, proxies upstream, then
// records usage back to vibe-id. Three latency optimizations vs the naive
// design (see wrangler.toml comment for the full rationale):
//
//   1. Service Binding (env.VIBE_ID.fetch). Calls to vibe-id run
//      in-process on the same edge node — no public-internet hop.
//   2. KV cache (env.CHECK_CACHE) on the /v1/check hot path. A recent
//      successful check for (token, endpoint) skips vibe-id entirely for
//      30 seconds. Used only for chat / transcribe-token where amount=1
//      (TTS amount varies with character count, so we always re-check).
//   3. ctx.waitUntil for /v1/record. Usage metering runs after the
//      response is sent — it doesn't add to perceived latency.

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ASSEMBLYAI_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;

  // Public URL for the browser-facing /auth/start redirect (we redirect the
  // user's browser to this URL so it has to be reachable from outside CF).
  VIBE_ID_BASE_URL: string;

  // Shared secret for vibe-id's internal endpoints (/v1/check and /v1/record).
  VIBE_ID_INTERNAL_KEY: string;

  // Service Binding to the deployed `vibe-id` worker (see wrangler.toml).
  VIBE_ID: Fetcher;

  // KV namespace for caching /v1/check decisions on the hot path.
  CHECK_CACHE: KVNamespace;
}

const PROJECT_ID = "dot";

// 30 seconds: short enough that signing out / hitting a daily limit becomes
// effective quickly (worst-case staleness window), long enough that an
// active multi-turn agent loop reuses the cache rather than hammering
// vibe-id between every step.
const CHECK_CACHE_TTL_SECONDS = 30;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const requestUrl = new URL(request.url);
    const pathname = requestUrl.pathname;
    const method = request.method;

    try {
      if (method === "GET" && pathname === "/health") {
        return jsonResponse({ ok: true, service: "dot-proxy" });
      }
      if (method === "GET" && pathname === "/auth/start") return handleAuthStartRedirect(request, env);
      if (method === "POST" && pathname === "/chat") return handleChat(request, env, ctx);
      if (method === "POST" && pathname === "/tts") return handleTextToSpeech(request, env, ctx);
      if (method === "POST" && pathname === "/transcribe-token") return handleTranscribeToken(request, env, ctx);
      return jsonResponse({ error: "not_found" }, 404);
    } catch (error) {
      console.error(`[${method} ${pathname}] unhandled:`, error);
      return jsonResponse({ error: "internal_error", message: String((error as Error)?.message ?? error) }, 500);
    }
  },
};

// Forwards to vibe-id with project=dot pre-set so the macOS app can keep
// pointing /auth/start at the dot proxy URL it already knows about.
//
// This is a 302 to vibe-id's PUBLIC URL (the user's browser follows the
// redirect, so it needs to be a real reachable URL — not a Service Binding).
function handleAuthStartRedirect(request: Request, env: Env): Response {
  const requestUrl = new URL(request.url);
  const targetUrl = new URL(`${env.VIBE_ID_BASE_URL.replace(/\/$/, "")}/auth/start`);
  targetUrl.searchParams.set("project", PROJECT_ID);
  for (const [key, value] of requestUrl.searchParams) {
    if (key === "device_id" || key === "return_to") {
      targetUrl.searchParams.set(key, value);
    }
  }
  return Response.redirect(targetUrl.toString(), 302);
}

async function handleChat(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const checkResult = await callVibeIdCheck(env, ctx, installToken, "chat", 1);
  if (!checkResult.ok) return checkResult.response;

  const requestBodyText = await request.text();

  const upstreamResponse = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: requestBodyText,
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/chat] Anthropic ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, { status: upstreamResponse.status, headers: { "content-type": "application/json" } });
  }

  // Fire-and-forget: usage recording runs after the response is sent.
  ctx.waitUntil(recordVibeIdUsage(env, installToken, "chat", 1, upstreamResponse.status));

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") ?? "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTextToSpeech(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const requestBodyText = await request.text();
  const ttsCharCount = extractTextLength(requestBodyText);
  if (ttsCharCount <= 0) return jsonResponse({ error: "tts_text_required" }, 400);
  if (ttsCharCount > 5000) return jsonResponse({ error: "tts_text_too_long", max_chars: 5000 }, 400);

  const checkResult = await callVibeIdCheck(env, ctx, installToken, "tts", ttsCharCount);
  if (!checkResult.ok) return checkResult.response;

  const upstreamResponse = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: requestBodyText,
    }
  );

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/tts] ElevenLabs ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, { status: upstreamResponse.status, headers: { "content-type": "application/json" } });
  }

  ctx.waitUntil(recordVibeIdUsage(env, installToken, "tts", ttsCharCount, upstreamResponse.status));

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: { "content-type": upstreamResponse.headers.get("content-type") ?? "audio/mpeg" },
  });
}

async function handleTranscribeToken(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const checkResult = await callVibeIdCheck(env, ctx, installToken, "transcribe-token", 1);
  if (!checkResult.ok) return checkResult.response;

  const upstreamResponse = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    { method: "GET", headers: { authorization: env.ASSEMBLYAI_API_KEY } }
  );

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/transcribe-token] AssemblyAI ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, { status: upstreamResponse.status, headers: { "content-type": "application/json" } });
  }

  ctx.waitUntil(recordVibeIdUsage(env, installToken, "transcribe-token", 1, upstreamResponse.status));

  const responseBodyText = await upstreamResponse.text();
  return new Response(responseBodyText, { status: 200, headers: { "content-type": "application/json" } });
}

// ============================================================================
// vibe-id integration
// ============================================================================

type CheckOk = { ok: true };
type CheckFail = { ok: false; response: Response };

/**
 * Verifies the install token + per-day quota with vibe-id.
 *
 * Caching: for endpoints where amount is fixed at 1 (chat, transcribe-token),
 * we cache a successful check for 30 seconds in KV. On a hit we skip the
 * Service-Bound vibe-id call entirely. For TTS the amount varies per request
 * (character count), so the cached "this user is within quota" answer doesn't
 * generalize — we always re-check.
 *
 * On vibe-id outage we fail closed (503) — quota enforcement is a feature
 * we want to preserve even when vibe-id is down. KV cache hits naturally
 * provide a small grace window for transient blips.
 */
async function callVibeIdCheck(
  env: Env,
  ctx: ExecutionContext,
  installToken: string,
  endpoint: string,
  amount: number
): Promise<CheckOk | CheckFail> {
  const tokenIsCacheable = endpoint === "chat" || endpoint === "transcribe-token";
  const cacheKey = tokenIsCacheable
    ? `check:${endpoint}:${await sha256Hex(installToken)}`
    : null;

  if (cacheKey) {
    const cachedDecision = await env.CHECK_CACHE.get(cacheKey);
    if (cachedDecision === "ok") {
      return { ok: true };
    }
  }

  let response: Response;
  try {
    // Service Binding: in-process call, no network hop.
    response = await env.VIBE_ID.fetch("https://vibe-id.internal/v1/check", {
      method: "POST",
      headers: { "content-type": "application/json", "x-internal-key": env.VIBE_ID_INTERNAL_KEY },
      body: JSON.stringify({ install_token: installToken, project: PROJECT_ID, endpoint, amount }),
    });
  } catch (error) {
    console.error(`[vibe-id /v1/check] service binding error: ${(error as Error).message}`);
    return { ok: false, response: jsonResponse({ error: "vibe_id_unreachable" }, 503) };
  }

  if (response.ok) {
    if (cacheKey) {
      ctx.waitUntil(env.CHECK_CACHE.put(cacheKey, "ok", { expirationTtl: CHECK_CACHE_TTL_SECONDS }));
    }
    return { ok: true };
  }

  const passthroughBody = await response.text();
  return {
    ok: false,
    response: new Response(passthroughBody, { status: response.status, headers: { "content-type": "application/json" } }),
  };
}

/**
 * Records a successful upstream call. Runs via ctx.waitUntil so it doesn't
 * hold the response open. Errors are logged and dropped — losing one usage
 * row is preferable to making the user wait on metering.
 */
async function recordVibeIdUsage(
  env: Env,
  installToken: string,
  endpoint: string,
  amount: number,
  statusCode: number
): Promise<void> {
  try {
    const response = await env.VIBE_ID.fetch("https://vibe-id.internal/v1/record", {
      method: "POST",
      headers: { "content-type": "application/json", "x-internal-key": env.VIBE_ID_INTERNAL_KEY },
      body: JSON.stringify({ install_token: installToken, project: PROJECT_ID, endpoint, amount, status_code: statusCode }),
    });
    if (!response.ok) {
      console.error(`[vibe-id /v1/record] ${response.status}: ${await response.text()}`);
    }
  } catch (error) {
    console.error(`[vibe-id /v1/record] service binding error: ${(error as Error).message}`);
  }
}

// ============================================================================
// Helpers
// ============================================================================

function readBearerToken(request: Request): string | null {
  const header = request.headers.get("authorization") ?? request.headers.get("Authorization");
  if (!header || !header.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length).trim();
  return token === "" ? null : token;
}

function extractTextLength(requestBodyText: string): number {
  try {
    const parsedBody = JSON.parse(requestBodyText) as { text?: unknown };
    return typeof parsedBody.text === "string" ? parsedBody.text.length : 0;
  } catch {
    return 0;
  }
}

async function sha256Hex(text: string): Promise<string> {
  const encoded = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function jsonResponse(payload: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}
