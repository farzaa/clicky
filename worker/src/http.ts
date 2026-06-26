export class HttpError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders(),
  });
}

export function preflightResponse(request: Request, env: Env): Response {
  const headers = new Headers({
    "allow": "GET,POST,OPTIONS",
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  });

  for (const [key, value] of Object.entries(corsHeadersForRequest(request, env))) {
    headers.set(key, value);
  }

  return new Response(null, {
    status: 204,
    headers,
  });
}

export function withCORS(response: Response, request: Request, env: Env): Response {
  const corsHeaders = corsHeadersForRequest(request, env);
  if (Object.keys(corsHeaders).length === 0) {
    return response;
  }

  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders)) {
    headers.set(key, value);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function htmlHeaders(): HeadersInit {
  return {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  };
}

export function escapeHTMLAttribute(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function jsonHeaders(): HeadersInit {
  return {
    "content-type": "application/json",
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  };
}

function corsHeadersForRequest(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get("origin");
  if (!origin || !isAllowedWebOrigin(origin, env)) {
    return {};
  }

  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization,content-type,stripe-signature,x-spider-device-id",
    "access-control-max-age": "86400",
    "vary": "Origin",
  };
}

function isAllowedWebOrigin(origin: string, env: Env): boolean {
  return allowedWebOrigins(env).includes(origin);
}

function allowedWebOrigins(env: Env): string[] {
  return (env.ALLOWED_WEB_ORIGINS || "")
    .split(",")
    .map((allowedOrigin) => normalizedAllowedWebOrigin(allowedOrigin))
    .filter((allowedOrigin): allowedOrigin is string => allowedOrigin !== null);
}

function normalizedAllowedWebOrigin(value: string): string | null {
  const trimmedValue = value.trim();
  if (!trimmedValue || trimmedValue === "*") {
    return null;
  }

  let url: URL;
  try {
    url = new URL(trimmedValue);
  } catch {
    return null;
  }

  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.pathname !== "/"
    || url.search
    || url.hash
  ) {
    return null;
  }

  return url.origin;
}
