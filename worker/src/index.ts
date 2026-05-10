// Dot inference proxy. Stateless forwarder: relays /chat, /tts, and
// /transcribe-token to vibe-id's /v1/proxy/* endpoints, which hold the
// upstream API keys, do auth + quota checks, and record usage. This worker
// holds zero secrets beyond VIBE_ID_INTERNAL_KEY, so the repo can be
// open-sourced and consumers point at the official vibe-id.
//
// The forward goes via a Service Binding (env.VIBE_ID.fetch) — an in-process
// call to vibe-id on the same edge node, no public HTTPS hop. The extra
// proxy layer costs ~0ms.

interface Env {
  VIBE_ID_INTERNAL_KEY: string;
  VIBE_ID: Fetcher;
}

const PROJECT_ID = "dot";
const VIBE_ID_INTERNAL_HOST = "https://internal.vibe-id";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestUrl = new URL(request.url);
    const pathname = requestUrl.pathname;
    const method = request.method;

    try {
      if (method === "GET" && pathname === "/health") {
        return jsonResponse({ ok: true, service: "dot-proxy" });
      }
      if (method === "POST" && pathname === "/chat") return forwardToVibeIdProxy(request, env, "chat");
      if (method === "POST" && pathname === "/tts") return forwardToVibeIdProxy(request, env, "tts");
      if (method === "POST" && pathname === "/transcribe-token") return forwardToVibeIdProxy(request, env, "transcribe-token");
      return jsonResponse({ error: "not_found" }, 404);
    } catch (error) {
      console.error(`[${method} ${pathname}] unhandled:`, error);
      return jsonResponse({ error: "internal_error", message: String((error as Error)?.message ?? error) }, 500);
    }
  },
};

async function forwardToVibeIdProxy(request: Request, env: Env, endpoint: "chat" | "tts" | "transcribe-token"): Promise<Response> {
  const userAuthHeader = request.headers.get("authorization") ?? request.headers.get("Authorization");
  if (!userAuthHeader) return jsonResponse({ error: "missing_bearer_token" }, 401);

  const requestBody = await request.arrayBuffer();
  const upstreamHeaders: Record<string, string> = {
    "authorization": userAuthHeader,
    "x-internal-key": env.VIBE_ID_INTERNAL_KEY,
    "x-project": PROJECT_ID,
  };
  const requestContentType = request.headers.get("content-type");
  if (requestContentType) upstreamHeaders["content-type"] = requestContentType;

  const upstreamResponse = await env.VIBE_ID.fetch(`${VIBE_ID_INTERNAL_HOST}/v1/proxy/${endpoint}`, {
    method: "POST",
    headers: upstreamHeaders,
    body: requestBody,
  });

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: passthroughResponseHeaders(upstreamResponse.headers),
  });
}

function passthroughResponseHeaders(upstreamHeaders: Headers): Headers {
  const passthrough = new Headers();
  const contentType = upstreamHeaders.get("content-type");
  if (contentType) passthrough.set("content-type", contentType);
  const cacheControl = upstreamHeaders.get("cache-control");
  if (cacheControl) passthrough.set("cache-control", cacheControl);
  return passthrough;
}

function jsonResponse(payload: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}
