// vibe-id project proxy template.
//
// Stateless forwarder: relays /chat, /tts, /transcribe-token (and any
// future endpoint you register in vibe-id's project_endpoints table) to
// vibe-id's /v1/proxy/* endpoints. vibe-id holds the upstream API keys,
// runs auth + quota + usage in one round trip.
//
// This worker holds zero secrets beyond VIBE_ID_INTERNAL_KEY. Total ~75
// LOC. Copy as-is for a new project — only `PROJECT_ID` below needs to
// change, plus the route in wrangler.toml.

interface Env {
  VIBE_ID_INTERNAL_KEY: string;
  VIBE_ID: Fetcher;
}

// CHANGE ME: must match the project id you registered in vibe-id's
// `projects` table.
const PROJECT_ID = "myproject";

// The hostname doesn't matter — Service Bindings ignore it. Pick something
// that's obviously synthetic so it's never confused with a real upstream.
const VIBE_ID_INTERNAL_HOST = "https://internal.vibe-id";

// Endpoints registered in vibe-id for this project. Adding a new one is
// (a) inserting a row in vibe-id's project_endpoints table, (b) adding the
// name here. No upstream-specific code in your worker.
const SUPPORTED_ENDPOINTS = ["chat", "tts", "transcribe-token"] as const;
type SupportedEndpoint = typeof SUPPORTED_ENDPOINTS[number];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestUrl = new URL(request.url);
    const pathname = requestUrl.pathname;
    const method = request.method;

    try {
      if (method === "GET" && pathname === "/health") {
        return jsonResponse({ ok: true, project: PROJECT_ID });
      }
      if (method === "POST" && pathname.startsWith("/")) {
        const endpointName = pathname.slice(1) as SupportedEndpoint;
        if ((SUPPORTED_ENDPOINTS as readonly string[]).includes(endpointName)) {
          return forwardToVibeIdProxy(request, env, endpointName);
        }
      }
      return jsonResponse({ error: "not_found" }, 404);
    } catch (error) {
      console.error(`[${method} ${pathname}] unhandled:`, error);
      return jsonResponse({ error: "internal_error", message: String((error as Error)?.message ?? error) }, 500);
    }
  },
};

async function forwardToVibeIdProxy(request: Request, env: Env, endpoint: SupportedEndpoint): Promise<Response> {
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
