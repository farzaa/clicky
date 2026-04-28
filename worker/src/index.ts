/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, Gemini, and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat         → Anthropic Messages API (streaming)
 *   POST /chat-gemini  → Google Gemini streamGenerateContent API (streaming SSE)
 *   POST /tts          → ElevenLabs TTS API
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  GEMINI_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/chat-gemini") {
        return await handleGeminiChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleGeminiChat(request: Request, env: Env): Promise<Response> {
  // Gemini's API puts the model in the URL path (not the body like Anthropic).
  // The app sends the model in a top-level `model` field in the JSON body;
  // we extract it here, construct the upstream URL, and forward the rest.
  const bodyText = await request.text();

  let parsedBody: { model?: string; [key: string]: unknown };
  try {
    parsedBody = JSON.parse(bodyText);
  } catch (parseError) {
    return new Response(
      JSON.stringify({ error: `Invalid JSON body: ${String(parseError)}` }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const requestedGeminiModel = parsedBody.model;
  if (typeof requestedGeminiModel !== "string" || requestedGeminiModel.length === 0) {
    return new Response(
      JSON.stringify({ error: "Missing or invalid 'model' field in request body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // Strip the model field from the body before forwarding — Gemini doesn't
  // expect it in the body and it's only used for URL construction.
  const { model: _omittedModel, ...geminiRequestBody } = parsedBody;

  const upstreamURL = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    requestedGeminiModel
  )}:streamGenerateContent?alt=sse&key=${env.GEMINI_API_KEY}`;

  const response = await fetch(upstreamURL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(geminiRequestBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat-gemini] Gemini API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
