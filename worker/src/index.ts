/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → Anthropic Messages API (streaming)
 *   POST /tts   → ElevenLabs TTS API
 *   POST /memory/search → Supermemory hybrid search
 *   POST /memory/add    → Supermemory document ingestion
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  SUPERMEMORY_API_KEY: string;
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

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/memory/search") {
        return await handleMemorySearch(request, env);
      }

      if (url.pathname === "/memory/add") {
        return await handleMemoryAdd(request, env);
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

async function handleMemorySearch(request: Request, env: Env): Promise<Response> {
  const incomingBody = await request.json() as {
    q?: string;
    containerTag?: string;
    limit?: number;
  };

  if (!incomingBody.q || !incomingBody.containerTag) {
    return new Response(
      JSON.stringify({ error: "q and containerTag are required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch("https://api.supermemory.ai/v4/search", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.SUPERMEMORY_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      q: incomingBody.q,
      containerTag: incomingBody.containerTag,
      searchMode: "hybrid",
      limit: Math.min(Math.max(incomingBody.limit ?? 5, 1), 10),
      threshold: 0.45,
    }),
  });

  const responseBody = await response.text();
  if (!response.ok) {
    console.error(`[/memory/search] Supermemory error ${response.status}: ${responseBody}`);
    return new Response(responseBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(responseBody, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleMemoryAdd(request: Request, env: Env): Promise<Response> {
  const incomingBody = await request.json() as {
    content?: string;
    containerTag?: string;
    metadata?: Record<string, unknown>;
  };

  if (!incomingBody.content || !incomingBody.containerTag) {
    return new Response(
      JSON.stringify({ error: "content and containerTag are required" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch("https://api.supermemory.ai/v3/documents", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.SUPERMEMORY_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      content: incomingBody.content,
      containerTags: [incomingBody.containerTag, "clicky"],
      metadata: {
        source: "clicky",
        ...incomingBody.metadata,
      },
    }),
  });

  const responseBody = await response.text();
  if (!response.ok) {
    console.error(`[/memory/add] Supermemory error ${response.status}: ${responseBody}`);
    return new Response(responseBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(responseBody, {
    status: response.status,
    headers: { "content-type": "application/json" },
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
