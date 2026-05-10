// Dot inference proxy. Stateless: verifies the bearer token with vibe-id,
// proxies upstream, then records usage back to vibe-id.

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ASSEMBLYAI_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  VIBE_ID_BASE_URL: string;
  VIBE_ID_INTERNAL_KEY: string;
}

const PROJECT_ID = "dot";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestUrl = new URL(request.url);
    const pathname = requestUrl.pathname;
    const method = request.method;

    try {
      if (method === "GET" && pathname === "/health") {
        return jsonResponse({ ok: true, service: "dot-proxy" });
      }
      if (method === "GET" && pathname === "/auth/start") return handleAuthStartRedirect(request, env);
      if (method === "POST" && pathname === "/chat") return handleChat(request, env);
      if (method === "POST" && pathname === "/tts") return handleTextToSpeech(request, env);
      if (method === "POST" && pathname === "/transcribe-token") return handleTranscribeToken(request, env);
      return jsonResponse({ error: "not_found" }, 404);
    } catch (error) {
      console.error(`[${method} ${pathname}] unhandled:`, error);
      return jsonResponse({ error: "internal_error", message: String((error as Error)?.message ?? error) }, 500);
    }
  },
};

// Forwards to vibe-id with project=dot pre-set so the macOS app can keep
// pointing /auth/start at the dot proxy URL it already knows about.
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

async function handleChat(request: Request, env: Env): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const checkResult = await callVibeIdCheck(env, installToken, "chat", 1);
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

  await recordVibeIdUsage(env, installToken, "chat", 1, upstreamResponse.status);

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") ?? "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTextToSpeech(request: Request, env: Env): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const requestBodyText = await request.text();
  const ttsCharCount = extractTextLength(requestBodyText);
  if (ttsCharCount <= 0) return jsonResponse({ error: "tts_text_required" }, 400);
  if (ttsCharCount > 5000) return jsonResponse({ error: "tts_text_too_long", max_chars: 5000 }, 400);

  const checkResult = await callVibeIdCheck(env, installToken, "tts", ttsCharCount);
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

  await recordVibeIdUsage(env, installToken, "tts", ttsCharCount, upstreamResponse.status);

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: { "content-type": upstreamResponse.headers.get("content-type") ?? "audio/mpeg" },
  });
}

async function handleTranscribeToken(request: Request, env: Env): Promise<Response> {
  const installToken = readBearerToken(request);
  if (!installToken) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const checkResult = await callVibeIdCheck(env, installToken, "transcribe-token", 1);
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

  await recordVibeIdUsage(env, installToken, "transcribe-token", 1, upstreamResponse.status);

  const responseBodyText = await upstreamResponse.text();
  return new Response(responseBodyText, { status: 200, headers: { "content-type": "application/json" } });
}

type CheckOk = { ok: true };
type CheckFail = { ok: false; response: Response };

async function callVibeIdCheck(env: Env, installToken: string, endpoint: string, amount: number): Promise<CheckOk | CheckFail> {
  let response: Response;
  try {
    response = await fetch(`${env.VIBE_ID_BASE_URL.replace(/\/$/, "")}/v1/check`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-internal-key": env.VIBE_ID_INTERNAL_KEY },
      body: JSON.stringify({ install_token: installToken, project: PROJECT_ID, endpoint, amount }),
    });
  } catch (error) {
    console.error(`[vibe-id /v1/check] network error: ${(error as Error).message}`);
    return { ok: false, response: jsonResponse({ error: "vibe_id_unreachable" }, 503) };
  }

  if (response.ok) return { ok: true };

  const passthroughBody = await response.text();
  return {
    ok: false,
    response: new Response(passthroughBody, { status: response.status, headers: { "content-type": "application/json" } }),
  };
}

async function recordVibeIdUsage(env: Env, installToken: string, endpoint: string, amount: number, statusCode: number): Promise<void> {
  try {
    const response = await fetch(`${env.VIBE_ID_BASE_URL.replace(/\/$/, "")}/v1/record`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-internal-key": env.VIBE_ID_INTERNAL_KEY },
      body: JSON.stringify({ install_token: installToken, project: PROJECT_ID, endpoint, amount, status_code: statusCode }),
    });
    if (!response.ok) {
      console.error(`[vibe-id /v1/record] ${response.status}: ${await response.text()}`);
    }
  } catch (error) {
    console.error(`[vibe-id /v1/record] network error: ${(error as Error).message}`);
  }
}

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

function jsonResponse(payload: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}
