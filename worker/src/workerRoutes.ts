import {
  accountReturnPageResponse,
  authLoginStatus,
  confirmMagicLinkLogin,
  revokeCurrentSession,
  startMagicLinkLogin,
} from "./authRoutes";
import { createBillingPortalSession, createCheckoutSession } from "./billingRoutes";
import { jsonResponse } from "./http";
import { createRealtimeClientSecret } from "./realtimeRoutes";
import { handleStripeWebhook } from "./stripeWebhookRoutes";
import { handleVisionGuide } from "./visionGuideRoutes";

type WorkerRoute = {
  method: string;
  pathname: string;
  handle: (request: Request, url: URL, env: Env) => Promise<Response> | Response;
};

const workerRoutes: WorkerRoute[] = [
  {
    method: "POST",
    pathname: "/auth/login/start",
    handle: (request, _url, env) => startMagicLinkLogin(request, env),
  },
  {
    method: "GET",
    pathname: "/auth/login/confirm",
    handle: (request, url, env) => confirmMagicLinkLogin(request, url, env),
  },
  {
    method: "GET",
    pathname: "/account",
    handle: () => accountReturnPageResponse(),
  },
  {
    method: "GET",
    pathname: "/auth/login/status",
    handle: (request, _url, env) => authLoginStatus(request, env),
  },
  {
    method: "POST",
    pathname: "/auth/logout",
    handle: (request, _url, env) => revokeCurrentSession(request, env),
  },
  {
    method: "POST",
    pathname: "/vision/guide",
    handle: (request, _url, env) => handleVisionGuide(request, env),
  },
  {
    method: "POST",
    pathname: "/realtime/client-secret",
    handle: (request, _url, env) => createRealtimeClientSecret(request, env),
  },
  {
    method: "POST",
    pathname: "/billing/checkout",
    handle: (request, _url, env) => createCheckoutSession(request, env),
  },
  {
    method: "POST",
    pathname: "/billing/portal",
    handle: (request, _url, env) => createBillingPortalSession(request, env),
  },
  {
    method: "POST",
    pathname: "/stripe/webhook",
    handle: (request, _url, env) => handleStripeWebhook(request, env),
  },
];

export async function routeWorkerRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const route = workerRoutes.find((candidate) => (
    candidate.method === request.method && candidate.pathname === url.pathname
  ));

  if (!route) {
    return jsonResponse({ error: "Not found" }, 404);
  }

  return await route.handle(request, url, env);
}
