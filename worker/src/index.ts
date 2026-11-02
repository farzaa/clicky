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
  ANTHROPIC_API_KEY?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
  CLICKY_PROXY_TOKEN?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const knownRoute = ["/chat", "/tts", "/transcribe-token"].includes(url.pathname);
    if (!knownRoute) {
      return new Response("Not found", { status: 404 });
    }

    const authorizationFailure = await authorizeProxyRequest(request, env);
    if (authorizationFailure) {
      return authorizationFailure;
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
      console.error(`[${url.pathname}] Unhandled upstream error:`, error);
      return new Response(
        JSON.stringify({ error: "The upstream service could not complete the request." }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function authorizeProxyRequest(request: Request, env: Env): Promise<Response | null> {
  const expectedToken = env.CLICKY_PROXY_TOKEN;
  if (!expectedToken) {
    return new Response(
      JSON.stringify({ error: "Worker authentication is not configured." }),
      { status: 503, headers: { "content-type": "application/json" } }
    );
  }

  const authorizationHeader = request.headers.get("authorization") ?? "";
  const providedToken = authorizationHeader.startsWith("Bearer ")
    ? authorizationHeader.slice("Bearer ".length)
    : "";

  if (!providedToken || !(await tokensMatch(providedToken, expectedToken))) {
    return new Response(
      JSON.stringify({ error: "A valid bearer token is required." }),
      {
        status: 401,
        headers: {
          "content-type": "application/json",
          "www-authenticate": "Bearer"
        }
      }
    );
  }

  return null;
}

async function tokensMatch(providedToken: string, expectedToken: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [providedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(providedToken)),
    crypto.subtle.digest("SHA-256", encoder.encode(expectedToken))
  ]);

  const providedBytes = new Uint8Array(providedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let difference = 0;

  for (let index = 0; index < expectedBytes.length; index += 1) {
    difference |= providedBytes[index] ^ expectedBytes[index];
  }

  return difference === 0;
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  const anthropicAPIKey = env.ANTHROPIC_API_KEY;
  if (!anthropicAPIKey) {
    return missingProviderSecretResponse();
  }

  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": anthropicAPIKey,
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

async function handleTranscribeToken(env: Env): Promise<Response> {
  const assemblyAIAPIKey = env.ASSEMBLYAI_API_KEY;
  if (!assemblyAIAPIKey) {
    return missingProviderSecretResponse();
  }

  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: assemblyAIAPIKey,
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
  const elevenLabsAPIKey = env.ELEVENLABS_API_KEY;
  const voiceId = env.ELEVENLABS_VOICE_ID;
  if (!elevenLabsAPIKey || !voiceId) {
    return missingProviderSecretResponse();
  }

  const body = await request.text();

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": elevenLabsAPIKey,
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

function missingProviderSecretResponse(): Response {
  return new Response(
    JSON.stringify({ error: "A required provider secret is not configured on this Worker." }),
    { status: 503, headers: { "content-type": "application/json" } }
  );
}
