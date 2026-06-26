import {
  HttpError,
  jsonResponse,
  preflightResponse,
  withCORS,
} from "./http";
import { pruneOperationalRows } from "./operationalRetentionStore";
import { routeWorkerRequest } from "./workerRoutes";

/**
 * Spider Worker
 *
 * Authenticates users, enforces paid entitlement and quota, and proxies OpenAI
 * calls without exposing API keys to the macOS app. User content is intentionally
 * not stored in D1 or logs.
 */

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return preflightResponse(request, env);
    }

    try {
      return withCORS(await routeWorkerRequest(request, env), request, env);
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      const message = error instanceof HttpError ? error.message : "Internal server error.";
      return withCORS(jsonResponse({ error: message }, status), request, env);
    }
  },

  async scheduled(
    _controller: ScheduledController,
    env: Env,
    ctx: ExecutionContext
  ): Promise<void> {
    ctx.waitUntil(pruneOperationalRows(env));
  },
};
