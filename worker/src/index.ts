/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → Anthropic Messages API (streaming)
 *   POST /tts   → ElevenLabs TTS API
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

/**
 * The Worker URL is public and every request spends the owner's API credits,
 * so only forward requests shaped like the ones the app sends. Anyone who
 * finds the URL can't use it as a general-purpose Anthropic/ElevenLabs proxy
 * with other models, bigger token budgets, tools, or arbitrary TTS payloads.
 *
 * If you add a model to the app's model picker, add it here too.
 */
const ALLOWED_CLAUDE_MODELS = new Set(["claude-sonnet-4-6", "claude-opus-4-6"]);
const MAX_CLAUDE_OUTPUT_TOKENS = 1024;
const ALLOWED_ELEVENLABS_MODELS = new Set(["eleven_flash_v2_5"]);
// A 1024-token Claude reply is roughly 4-5k characters; leave headroom for
// languages that use more characters per token.
const MAX_TTS_TEXT_CHARACTERS = 10_000;

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
  const requestedChatBody = await readJSONObjectBody(request);
  if (!requestedChatBody) {
    return jsonErrorResponse(400, "Request body must be a JSON object.");
  }

  const requestedModel = requestedChatBody.model;
  if (typeof requestedModel !== "string" || !ALLOWED_CLAUDE_MODELS.has(requestedModel)) {
    return jsonErrorResponse(400, `Model is not allowed by this proxy: ${String(requestedModel)}`);
  }

  if (!Array.isArray(requestedChatBody.messages) || requestedChatBody.messages.length === 0) {
    return jsonErrorResponse(400, "messages must be a non-empty array.");
  }

  const requestedMaxTokens =
    typeof requestedChatBody.max_tokens === "number" && Number.isFinite(requestedChatBody.max_tokens)
      ? Math.floor(requestedChatBody.max_tokens)
      : MAX_CLAUDE_OUTPUT_TOKENS;

  // Rebuild the body from only the fields the app sends, so anything else
  // (tools, extended thinking, a larger budget) can't ride along on our key.
  const forwardedChatBody = {
    model: requestedModel,
    max_tokens: Math.min(Math.max(requestedMaxTokens, 1), MAX_CLAUDE_OUTPUT_TOKENS),
    stream: requestedChatBody.stream === true,
    system: typeof requestedChatBody.system === "string" ? requestedChatBody.system : undefined,
    messages: requestedChatBody.messages,
  };

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(forwardedChatBody),
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
  const requestedTTSBody = await readJSONObjectBody(request);
  if (!requestedTTSBody) {
    return jsonErrorResponse(400, "Request body must be a JSON object.");
  }

  const requestedText = requestedTTSBody.text;
  if (typeof requestedText !== "string" || requestedText.trim().length === 0) {
    return jsonErrorResponse(400, "text must be a non-empty string.");
  }
  if (requestedText.length > MAX_TTS_TEXT_CHARACTERS) {
    return jsonErrorResponse(400, `text is longer than ${MAX_TTS_TEXT_CHARACTERS} characters.`);
  }

  const requestedTTSModel = requestedTTSBody.model_id;
  if (typeof requestedTTSModel !== "string" || !ALLOWED_ELEVENLABS_MODELS.has(requestedTTSModel)) {
    return jsonErrorResponse(400, `TTS model is not allowed by this proxy: ${String(requestedTTSModel)}`);
  }

  const forwardedTTSBody = {
    text: requestedText,
    model_id: requestedTTSModel,
    voice_settings: isJSONObject(requestedTTSBody.voice_settings) ? requestedTTSBody.voice_settings : undefined,
  };

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
      body: JSON.stringify(forwardedTTSBody),
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

function isJSONObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Parses the request body as a JSON object, or returns null if it isn't one. */
async function readJSONObjectBody(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const parsedBody: unknown = await request.json();
    return isJSONObject(parsedBody) ? parsedBody : null;
  } catch {
    // Malformed JSON is rejected the same way as a non-object body.
    return null;
  }
}

function jsonErrorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
