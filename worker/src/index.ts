/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat             → Anthropic Messages API (streaming)
 *   POST /tts              → ElevenLabs TTS API
 *   POST /transcribe-token → AssemblyAI temporary websocket token
 *
 * Hardening:
 *   - Per-IP sliding-window rate limiting on /chat and /tts
 *   - Structured JSON error responses with error codes
 *   - Request logging (method, route, IP, status) for wrangler tail
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

// --- Structured error codes returned in all error responses ---
type ErrorCode = "RATE_LIMITED" | "UPSTREAM_ERROR" | "BAD_REQUEST" | "INTERNAL_ERROR";

interface StructuredErrorBody {
  error: string;
  code: ErrorCode;
}

const JSON_CONTENT_TYPE_HEADER = { "content-type": "application/json" };

/**
 * Build a structured JSON error Response.
 * Every error path in the worker funnels through here so the client always
 * receives a consistent `{ error, code }` shape.
 */
function buildStructuredErrorResponse(
  httpStatus: number,
  errorMessage: string,
  errorCode: ErrorCode,
): Response {
  const body: StructuredErrorBody = { error: errorMessage, code: errorCode };
  return new Response(JSON.stringify(body), {
    status: httpStatus,
    headers: JSON_CONTENT_TYPE_HEADER,
  });
}

// --- Per-IP sliding-window rate limiter ---

/**
 * Each entry stores the timestamps (in ms) of recent requests from a single IP
 * for a single route. Timestamps older than the window are pruned on every check.
 *
 * We use an in-memory Map because Cloudflare Workers keep the module-level
 * scope alive across requests on the same isolate. This gives us lightweight,
 * per-isolate rate limiting without external storage. The trade-off is that
 * limits reset when the isolate is evicted, but that is acceptable for
 * abuse-prevention (not billing-grade) rate limiting.
 */
interface SlidingWindowEntry {
  requestTimestamps: number[];
}

interface RateLimitConfiguration {
  maxRequestsPerWindow: number;
  windowDurationMilliseconds: number;
}

// Separate rate-limit buckets per route so /chat and /tts limits are independent.
const rateLimitBucketsByRoute = new Map<string, Map<string, SlidingWindowEntry>>();

const RATE_LIMIT_CONFIG_BY_ROUTE: Record<string, RateLimitConfiguration> = {
  "/chat": {
    maxRequestsPerWindow: 20,
    // 60 seconds (1 minute)
    windowDurationMilliseconds: 60_000,
  },
  "/tts": {
    maxRequestsPerWindow: 30,
    windowDurationMilliseconds: 60_000,
  },
};

/**
 * Returns `true` if the request should be allowed, `false` if the IP has
 * exceeded the rate limit for the given route.
 *
 * Side-effect: records the current timestamp into the sliding window when the
 * request is allowed.
 */
function isRequestAllowedByRateLimit(clientIpAddress: string, routePath: string): boolean {
  const routeConfiguration = RATE_LIMIT_CONFIG_BY_ROUTE[routePath];
  if (!routeConfiguration) {
    // No rate-limit configured for this route — always allow.
    return true;
  }

  // Lazily create the per-route bucket map.
  if (!rateLimitBucketsByRoute.has(routePath)) {
    rateLimitBucketsByRoute.set(routePath, new Map());
  }
  const routeBuckets = rateLimitBucketsByRoute.get(routePath)!;

  const currentTimestamp = Date.now();
  const windowStartTimestamp = currentTimestamp - routeConfiguration.windowDurationMilliseconds;

  // Lazily create the entry for this IP.
  if (!routeBuckets.has(clientIpAddress)) {
    routeBuckets.set(clientIpAddress, { requestTimestamps: [] });
  }
  const ipEntry = routeBuckets.get(clientIpAddress)!;

  // Prune timestamps that have fallen outside the sliding window.
  ipEntry.requestTimestamps = ipEntry.requestTimestamps.filter(
    (timestamp) => timestamp > windowStartTimestamp,
  );

  if (ipEntry.requestTimestamps.length >= routeConfiguration.maxRequestsPerWindow) {
    return false;
  }

  // Record this request's timestamp so it counts toward the window.
  ipEntry.requestTimestamps.push(currentTimestamp);
  return true;
}

// --- Request logging ---

/**
 * Logs a single-line summary of each request for observability via `wrangler tail`.
 * Format: "[POST /chat] ip=203.0.113.42 → 200"
 */
function logRequestSummary(
  httpMethod: string,
  routePath: string,
  clientIpAddress: string,
  responseStatus: number,
): void {
  console.log(
    `[${httpMethod} ${routePath}] ip=${clientIpAddress} → ${responseStatus}`,
  );
}

// --- Main fetch handler ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const routePath = url.pathname;
    const clientIpAddress = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const httpMethod = request.method;

    // --- Method check ---
    if (httpMethod !== "POST") {
      const response = buildStructuredErrorResponse(
        405,
        "Method not allowed. Only POST requests are accepted.",
        "BAD_REQUEST",
      );
      logRequestSummary(httpMethod, routePath, clientIpAddress, 405);
      return response;
    }

    // --- Rate limiting (applied before any upstream work) ---
    if (!isRequestAllowedByRateLimit(clientIpAddress, routePath)) {
      const rateLimitConfig = RATE_LIMIT_CONFIG_BY_ROUTE[routePath];
      const windowSeconds = rateLimitConfig
        ? rateLimitConfig.windowDurationMilliseconds / 1000
        : 60;
      const response = buildStructuredErrorResponse(
        429,
        `Rate limit exceeded. Try again in ${windowSeconds} seconds.`,
        "RATE_LIMITED",
      );
      logRequestSummary(httpMethod, routePath, clientIpAddress, 429);
      return response;
    }

    // --- Route dispatch ---
    try {
      let response: Response;

      if (routePath === "/chat") {
        response = await handleChat(request, env);
      } else if (routePath === "/tts") {
        response = await handleTTS(request, env);
      } else if (routePath === "/transcribe-token") {
        response = await handleTranscribeToken(env);
      } else {
        response = buildStructuredErrorResponse(
          404,
          `Route not found: ${routePath}`,
          "BAD_REQUEST",
        );
      }

      logRequestSummary(httpMethod, routePath, clientIpAddress, response.status);
      return response;
    } catch (error) {
      console.error(`[${routePath}] Unhandled error:`, error);
      const response = buildStructuredErrorResponse(
        500,
        "An internal error occurred. Please try again later.",
        "INTERNAL_ERROR",
      );
      logRequestSummary(httpMethod, routePath, clientIpAddress, 500);
      return response;
    }
  },
};

// --- Route handlers ---

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!anthropicResponse.ok) {
    const upstreamErrorBody = await anthropicResponse.text();
    console.error(
      `[/chat] Anthropic API error ${anthropicResponse.status}: ${upstreamErrorBody}`,
    );
    return buildStructuredErrorResponse(
      anthropicResponse.status,
      `Anthropic API error: ${upstreamErrorBody}`,
      "UPSTREAM_ERROR",
    );
  }

  return new Response(anthropicResponse.body, {
    status: anthropicResponse.status,
    headers: {
      "content-type":
        anthropicResponse.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const assemblyAiResponse = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    },
  );

  if (!assemblyAiResponse.ok) {
    const upstreamErrorBody = await assemblyAiResponse.text();
    console.error(
      `[/transcribe-token] AssemblyAI token error ${assemblyAiResponse.status}: ${upstreamErrorBody}`,
    );
    return buildStructuredErrorResponse(
      assemblyAiResponse.status,
      `AssemblyAI token error: ${upstreamErrorBody}`,
      "UPSTREAM_ERROR",
    );
  }

  const tokenResponseData = await assemblyAiResponse.text();
  return new Response(tokenResponseData, {
    status: 200,
    headers: JSON_CONTENT_TYPE_HEADER,
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const elevenLabsResponse = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    },
  );

  if (!elevenLabsResponse.ok) {
    const upstreamErrorBody = await elevenLabsResponse.text();
    console.error(
      `[/tts] ElevenLabs API error ${elevenLabsResponse.status}: ${upstreamErrorBody}`,
    );
    return buildStructuredErrorResponse(
      elevenLabsResponse.status,
      `ElevenLabs API error: ${upstreamErrorBody}`,
      "UPSTREAM_ERROR",
    );
  }

  return new Response(elevenLabsResponse.body, {
    status: elevenLabsResponse.status,
    headers: {
      "content-type":
        elevenLabsResponse.headers.get("content-type") || "audio/mpeg",
    },
  });
}
