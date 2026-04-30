/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, ElevenLabs, AssemblyAI, and Gemini APIs
 * so the app never ships with raw API keys. Keys are stored as
 * Cloudflare secrets.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (streaming)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI temp token
 *   POST /youtube           → Generate a tutorial step plan from a YouTube video (Gemini)
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  GEMINI_API_KEY: string;
}

const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "Content-Type",
};

/** Add CORS headers to any Response. */
function withCORS(response: Response): Response {
  const newHeaders = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    newHeaders.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (request.method !== "POST") {
      return withCORS(new Response("Method not allowed", { status: 405 }));
    }

    try {
      if (url.pathname === "/chat") {
        return withCORS(await handleChat(request, env));
      }

      if (url.pathname === "/tts") {
        return withCORS(await handleTTS(request, env));
      }

      if (url.pathname === "/transcribe-token") {
        return withCORS(await handleTranscribeToken(env));
      }

      if (url.pathname === "/youtube") {
        return withCORS(await handleYoutube(request, env));
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return withCORS(new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      ));
    }

    return withCORS(new Response("Not found", { status: 404 }));
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

/* -------------------------------------------------------------------------- */
/*                                   YouTube                                  */
/* -------------------------------------------------------------------------- */

const YOUTUBE_URL_REGEX =
  /^https?:\/\/(?:www\.|m\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/)|youtu\.be\/)([A-Za-z0-9_-]{6,15})(?:[?&#].*)?$/;

const GEMINI_MODEL = "gemini-2.5-flash";

const STEP_PLAN_SCHEMA = {
  type: "object",
  properties: {
    refusal: {
      type: "string",
      description:
        "If this is not an instructional video, set this to a brief reason and omit the other fields.",
    },
    title: { type: "string" },
    summary: { type: "string" },
    browserCompatible: { type: "boolean" },
    shareRecommendation: {
      type: "object",
      properties: {
        scope: { type: "string", enum: ["browser", "window", "screen"] },
        reason: { type: "string" },
      },
      required: ["scope", "reason"],
    },
    steps: {
      type: "array",
      items: {
        type: "object",
        properties: {
          number: { type: "integer" },
          description: { type: "string" },
          stepType: {
            type: "string",
            enum: ["navigate", "click", "type", "verify", "wait", "info"],
          },
          visualHint: { type: "string" },
          demoInput: { type: "string" },
          expectedDuration: { type: "integer" },
        },
        required: ["number", "description", "stepType"],
      },
    },
  },
};

const STEP_PLAN_PROMPT = `You are extracting a step-by-step tutorial workflow from the attached video.

Output JSON matching the response schema.

Rules:
- title: short, action-oriented (max 60 chars). Example: "Post your first article on LinkedIn".
- summary: one or two sentences describing what the user will accomplish.
- steps: atomic user actions. One step = one action the USER takes that produces a visible change. Number them sequentially starting at 1. Aim for 5–25 steps.
- DO NOT include the presenter's intro, outro, sponsor reads, or commentary about the host.
- DO NOT include actions the presenter does that the user does not need to copy (e.g. "the dashboard you see is mine").
- DO include "verify" steps where the user should confirm a state ("the post appears in your feed").
- stepType must be one of: navigate, click, type, verify, wait, info.
- visualHint: a short cue for what the user should see when the step is done.
- demoInput: only for type steps where a sample value helps the user move forward.
- expectedDuration: rough seconds for an average user to complete this step.
- browserCompatible: true ONLY if the entire workflow happens inside a web browser.
- shareRecommendation.scope: "browser" if entirely in a browser tab; "window" if a single desktop app; "screen" if it spans multiple windows.

If this video is NOT a tutorial (music video, vlog, ad, abstract demo with no clear user actions), set the "refusal" field to a one-sentence reason and omit the other fields. Do this before guessing.`;

interface YoutubeRequestBody {
  videoUrl?: string;
}

async function handleYoutube(request: Request, env: Env): Promise<Response> {
  if (!env.GEMINI_API_KEY) {
    return new Response(
      JSON.stringify({ error: "GEMINI_API_KEY is not configured" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  let body: YoutubeRequestBody;
  try {
    body = await request.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Body must be JSON: { videoUrl }" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const videoUrl = (body.videoUrl || "").trim();
  if (!YOUTUBE_URL_REGEX.test(videoUrl)) {
    return new Response(
      JSON.stringify({
        error:
          "videoUrl must be a public YouTube URL (youtube.com/watch?v=…, youtu.be/…, or shorts/embed).",
      }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const geminiBody = {
    contents: [
      {
        parts: [
          { fileData: { fileUri: videoUrl, mimeType: "video/*" } },
          { text: STEP_PLAN_PROMPT },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.4,
      responseMimeType: "application/json",
      responseSchema: STEP_PLAN_SCHEMA,
    },
  };

  const geminiUrl =
    `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=` +
    encodeURIComponent(env.GEMINI_API_KEY);

  const response = await fetch(geminiUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(geminiBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/youtube] Gemini API error ${response.status}: ${errorBody}`);
    return new Response(
      JSON.stringify({
        error: "Gemini request failed",
        status: response.status,
        detail: safeJsonParse(errorBody),
      }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  let payload: any;
  try {
    payload = await response.json();
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Gemini returned a non-JSON body" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const text: string | undefined =
    payload?.candidates?.[0]?.content?.parts?.[0]?.text;

  if (!text) {
    console.error("[/youtube] Gemini returned no text candidate", payload);
    return new Response(
      JSON.stringify({ error: "Gemini returned no content", raw: payload }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const plan = safeJsonParse(text);
  if (!plan || typeof plan !== "object") {
    return new Response(
      JSON.stringify({ error: "Gemini returned non-JSON content", raw: text }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  return new Response(JSON.stringify({ plan, videoUrl }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function safeJsonParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
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
