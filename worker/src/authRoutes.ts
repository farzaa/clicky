import { recordAuditEvent } from "./auditEventStore";
import {
  consumeActiveMagicLinkByHash,
  consumeMagicLinkByHash,
  createDeviceBoundSession,
  createMagicLink,
  findAuthenticatedUserBySession,
  findUsableMagicLinkByHash,
  findUserByEmailHash,
  revokePreviousActiveMagicLinks,
  revokeSessionByHash,
  upsertUserByEmailHash,
  type AuthenticatedUser,
  type MagicLinkRecord,
} from "./authSessionStore";
import { effectiveEntitlementStatus } from "./entitlementPolicy";
import { HttpError, escapeHTMLAttribute, htmlHeaders, jsonResponse } from "./http";
import {
  clientIPAddressFromRequest,
  deviceIdentifierFromRequest,
  magicLinkTokenFromURL,
  requiredDeviceHashFromRequest,
  sessionTokenHashFromRequest,
  sha256Hex,
} from "./identitySecurity";
import { consumeDailyActorRateLimit, consumeDailyUserQuota } from "./meteringStore";
import { readJSONRequest } from "./payloadSecurity";
import {
  emailHashForStorage,
  magicLinkConfirmURL,
  magicLinkDeepLinkURL,
  normalizeEmail,
  numericEnv,
  requireMagicLinkDelivery,
} from "./runtimeConfig";

const MAX_AUTH_BODY_BYTES = 4_096;

export async function startMagicLinkLogin(request: Request, env: Env): Promise<Response> {
  const body = await readJSONRequest<{ email?: string }>(request, MAX_AUTH_BODY_BYTES);
  const email = normalizeEmail(body.email);
  await requiredDeviceHashFromRequest(request);
  requireMagicLinkDelivery(env);
  const confirmURL = magicLinkConfirmURL(request, env);

  await consumeRequestRateLimits(request, env, "auth_start", {
    ipLimit: numericEnv(env.DAILY_IP_AUTH_START_LIMIT, 12),
    deviceLimit: numericEnv(env.DAILY_DEVICE_AUTH_START_LIMIT, 12),
  });

  const emailHash = await emailHashForStorage(env, email);
  const userId = crypto.randomUUID();

  await upsertUserByEmailHash(env, { id: userId, emailHash });
  const user = await findUserByEmailHash(env, emailHash);
  if (!user) {
    throw new HttpError(500, "Could not create user.");
  }

  const rawToken = crypto.randomUUID() + crypto.randomUUID();
  const tokenHash = await sha256Hex(rawToken);
  const expiresAt = Math.floor(Date.now() / 1000) + 15 * 60;

  await createMagicLink(env, { tokenHash, userId: user.id, expiresAt });
  confirmURL.searchParams.set("token", rawToken);

  try {
    await sendMagicLinkEmail(env, email, confirmURL.toString());
  } catch (error) {
    await consumeMagicLinkByHash(env, tokenHash);
    throw error;
  }

  await revokePreviousActiveMagicLinks(env, user.id, tokenHash);
  await recordAuditEvent(env, user.id, "auth_magic_link_started");

  const responseBody: Record<string, unknown> = { ok: true };
  if (env.DEV_RETURN_MAGIC_LINK === "1") {
    responseBody.magicLink = confirmURL.toString();
  }
  return jsonResponse(responseBody);
}

export async function confirmMagicLinkLogin(request: Request, url: URL, env: Env): Promise<Response> {
  const token = magicLinkTokenFromURL(url);

  if (wantsHTML(request)) {
    await consumeRequestRateLimits(request, env, "auth_confirm", {
      ipLimit: numericEnv(env.DAILY_IP_AUTH_CONFIRM_LIMIT, 30),
      deviceLimit: numericEnv(env.DAILY_DEVICE_AUTH_CONFIRM_LIMIT, 30),
    });
    await requireUsableMagicLink(env, token);
    return magicLinkBrowserBridgeResponse(env, token);
  }

  const deviceHash = await requiredDeviceHashFromRequest(request);
  await consumeRequestRateLimits(request, env, "auth_confirm", {
    ipLimit: numericEnv(env.DAILY_IP_AUTH_CONFIRM_LIMIT, 30),
    deviceLimit: numericEnv(env.DAILY_DEVICE_AUTH_CONFIRM_LIMIT, 30),
  });
  const tokenHash = await sha256Hex(token);
  const magicLink = await requireUsableMagicLinkByHash(env, tokenHash);

  const consumedMagicLink = await consumeActiveMagicLinkByHash(env, tokenHash);
  if (!consumedMagicLink) {
    throw new HttpError(401, "Magic link is invalid or expired.");
  }

  const sessionToken = crypto.randomUUID() + crypto.randomUUID();
  const sessionTokenHash = await sha256Hex(sessionToken);
  const expiresAt = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 30;

  await createDeviceBoundSession(env, {
    tokenHash: sessionTokenHash,
    userId: magicLink.userId,
    expiresAt,
    deviceHash,
  });
  await recordAuditEvent(env, magicLink.userId, "auth_session_created");

  return jsonResponse({
    sessionToken,
    expiresAt,
  });
}

export function accountReturnPageResponse(): Response {
  return new Response(
    `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Return to Spider</title>
  <style>
    body {
      background: #0b0d12;
      color: #f5f7fb;
      font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
    }
    main {
      width: min(420px, calc(100vw - 48px));
      line-height: 1.45;
    }
    p {
      color: #aeb7c8;
    }
  </style>
</head>
<body>
  <main>
    <h1>Return to Spider</h1>
    <p>Your account flow is complete. Open Spider from the menu bar to continue.</p>
  </main>
</body>
</html>`,
    {
      status: 200,
      headers: htmlHeaders(),
    }
  );
}

export async function authLoginStatus(request: Request, env: Env): Promise<Response> {
  const user = await requireUser(request, env);
  return jsonResponse({
    authenticated: true,
    entitlementStatus: effectiveEntitlementStatus(user),
    stripeCustomerId: user.stripeCustomerId,
  });
}

export async function revokeCurrentSession(request: Request, env: Env): Promise<Response> {
  const user = await requireUser(request, env);
  const tokenHash = await sessionTokenHashFromRequest(request);

  await revokeSessionByHash(env, tokenHash);
  await recordAuditEvent(env, user.id, "auth_session_revoked");

  return jsonResponse({ ok: true });
}

export async function requireUser(request: Request, env: Env): Promise<AuthenticatedUser> {
  const tokenHash = await sessionTokenHashFromRequest(request);
  const deviceHash = await requiredDeviceHashFromRequest(request);
  const user = await findAuthenticatedUserBySession(env, { tokenHash, deviceHash });
  if (!user) {
    throw new HttpError(401, "Invalid or expired session.");
  }

  return user;
}

export async function requirePaidUser(request: Request, env: Env): Promise<AuthenticatedUser> {
  const user = await requireUser(request, env);
  const entitlementStatus = effectiveEntitlementStatus(user);
  if (entitlementStatus !== "active" && entitlementStatus !== "trial") {
    throw new HttpError(402, "Active subscription required.");
  }
  return user;
}

export async function consumeQuota(
  env: Env,
  userId: string,
  quotaKind: string,
  dailyLimit: number
): Promise<void> {
  const today = new Date().toISOString().slice(0, 10);
  const consumedCounter = await consumeDailyUserQuota(env, {
    userId,
    quotaKind,
    day: today,
    dailyLimit,
  });

  if (!consumedCounter) {
    throw new HttpError(429, `${quotaKind} daily quota exceeded.`);
  }
}

export async function consumeRequestRateLimits(
  request: Request,
  env: Env,
  quotaKind: string,
  limits: { ipLimit: number; deviceLimit: number }
): Promise<void> {
  const deviceIdentifier = deviceIdentifierFromRequest(request);
  const ipAddress = clientIPAddressFromRequest(request);

  if (ipAddress) {
    await consumeActorRateLimit(env, `ip:${await sha256Hex(ipAddress)}`, quotaKind, limits.ipLimit);
  }

  if (deviceIdentifier) {
    await consumeActorRateLimit(
      env,
      `device:${await sha256Hex(deviceIdentifier)}`,
      quotaKind,
      limits.deviceLimit
    );
  }
}

async function consumeActorRateLimit(
  env: Env,
  actorHash: string,
  quotaKind: string,
  dailyLimit: number
): Promise<void> {
  const today = new Date().toISOString().slice(0, 10);
  const consumedCounter = await consumeDailyActorRateLimit(env, {
    actorHash,
    quotaKind,
    day: today,
    dailyLimit,
  });

  if (!consumedCounter) {
    throw new HttpError(429, `${quotaKind} rate limit exceeded.`);
  }
}

async function requireUsableMagicLink(env: Env, token: string): Promise<MagicLinkRecord> {
  return await requireUsableMagicLinkByHash(env, await sha256Hex(token));
}

async function requireUsableMagicLinkByHash(env: Env, tokenHash: string): Promise<MagicLinkRecord> {
  const magicLink = await findUsableMagicLinkByHash(env, tokenHash, Math.floor(Date.now() / 1000));
  if (!magicLink) {
    throw new HttpError(401, "Magic link is invalid or expired.");
  }

  return magicLink;
}

function wantsHTML(request: Request): boolean {
  const accept = request.headers.get("accept") || "";
  return accept.includes("text/html") && !accept.includes("application/json");
}

function magicLinkBrowserBridgeResponse(env: Env, token: string): Response {
  const appURL = magicLinkDeepLinkURL(env);
  appURL.searchParams.set("token", token);
  const appURLString = appURL.toString();

  return new Response(
    `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="0; url=${escapeHTMLAttribute(appURLString)}">
  <title>Open Spider</title>
  <style>
    body {
      background: #0b0d12;
      color: #f5f7fb;
      font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
    }
    main {
      width: min(420px, calc(100vw - 48px));
      line-height: 1.45;
    }
    a {
      color: #f5f7fb;
      background: #2f6df6;
      border-radius: 8px;
      display: inline-block;
      font-weight: 700;
      margin-top: 14px;
      padding: 10px 14px;
      text-decoration: none;
    }
    p {
      color: #aeb7c8;
    }
  </style>
</head>
<body>
  <main>
    <h1>Open Spider</h1>
    <p>Your login link is valid. If Spider does not open automatically, use the button below.</p>
    <a href="${escapeHTMLAttribute(appURLString)}">Open Spider</a>
  </main>
</body>
</html>`,
    {
      status: 200,
      headers: htmlHeaders(),
    }
  );
}

async function sendMagicLinkEmail(env: Env, email: string, magicLink: string): Promise<void> {
  if (!env.RESEND_API_KEY || !env.MAGIC_LINK_FROM) {
    if (env.DEV_RETURN_MAGIC_LINK === "1") {
      return;
    }
    throw new HttpError(500, "Email delivery is not configured.");
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.RESEND_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: env.MAGIC_LINK_FROM,
      to: email,
      subject: "Your Spider login link",
      text: `Open this link to sign in to Spider:\n\n${magicLink}\n\nThis link expires in 15 minutes.`,
    }),
  });

  if (!response.ok) {
    throw new HttpError(502, "Could not send magic link email.");
  }
}
