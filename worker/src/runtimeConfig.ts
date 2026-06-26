import { HttpError } from "./http";
import { hmacSHA256Hex, sha256Hex } from "./identitySecurity";

const MAX_EMAIL_CHARS = 254;
const EMAIL_PATTERN = /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$/i;
const OPENAI_MODEL_NAME_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

export function normalizeEmail(email: unknown): string {
  if (typeof email !== "string") {
    throw new HttpError(400, "Email is required.");
  }
  const normalized = email.trim().toLowerCase();
  if (
    !normalized
    || normalized.length > MAX_EMAIL_CHARS
    || !isASCIIString(normalized)
    || !EMAIL_PATTERN.test(normalized)
  ) {
    throw new HttpError(400, "Email is invalid.");
  }
  return normalized;
}

export async function emailHashForStorage(env: Env, email: string): Promise<string> {
  if (env.EMAIL_HASH_SECRET) {
    return await hmacSHA256Hex(env.EMAIL_HASH_SECRET, email);
  }

  if (env.DEV_RETURN_MAGIC_LINK === "1") {
    return await sha256Hex(`dev-email:${email}`);
  }

  throw new HttpError(500, "Email hashing is not configured.");
}

export function requireMagicLinkDelivery(env: Env): void {
  if ((!env.RESEND_API_KEY || !env.MAGIC_LINK_FROM) && env.DEV_RETURN_MAGIC_LINK !== "1") {
    throw new HttpError(500, "Email delivery is not configured.");
  }
}

export function magicLinkConfirmURL(request: Request, env: Env): URL {
  const fallbackURL = `${new URL(request.url).origin}/auth/login/confirm`;
  const confirmURL = parseConfiguredURL(env.APP_LOGIN_CONFIRM_URL || fallbackURL, "APP_LOGIN_CONFIRM_URL");
  const isDevelopmentMagicLink = env.DEV_RETURN_MAGIC_LINK === "1";

  if (isDevelopmentMagicLink) {
    if (!["https:", "http:", "spider:"].includes(confirmURL.protocol)) {
      throw new HttpError(500, "APP_LOGIN_CONFIRM_URL has an invalid scheme.");
    }
    return confirmURL;
  }

  requireProductionHTTPSURL(confirmURL.toString(), "APP_LOGIN_CONFIRM_URL");
  if (!confirmURL.pathname.endsWith("/auth/login/confirm")) {
    throw new HttpError(500, "APP_LOGIN_CONFIRM_URL must point to /auth/login/confirm.");
  }
  return confirmURL;
}

export function magicLinkDeepLinkURL(env: Env): URL {
  const deepLinkURL = parseConfiguredURL(env.APP_LOGIN_DEEP_LINK_URL || "spider://auth/confirm", "APP_LOGIN_DEEP_LINK_URL");
  if (deepLinkURL.protocol !== "spider:" || deepLinkURL.host !== "auth" || deepLinkURL.pathname !== "/confirm") {
    throw new HttpError(500, "APP_LOGIN_DEEP_LINK_URL must be spider://auth/confirm.");
  }
  return deepLinkURL;
}

export function requireStripeRedirectURLs(env: Env): void {
  if (!env.STRIPE_SUCCESS_URL || !env.STRIPE_CANCEL_URL) {
    throw new HttpError(500, "Stripe redirect URLs are not configured.");
  }
  requireProductionHTTPSURL(env.STRIPE_SUCCESS_URL, "STRIPE_SUCCESS_URL");
  requireProductionHTTPSURL(env.STRIPE_CANCEL_URL, "STRIPE_CANCEL_URL");
}

export function requireStripePriceID(env: Env): string {
  if (!env.STRIPE_PRICE_ID) {
    throw new HttpError(500, "Stripe price is not configured.");
  }
  return env.STRIPE_PRICE_ID;
}

export function requireStripeAPISecret(env: Env): string {
  if (!env.STRIPE_SECRET_KEY) {
    throw new HttpError(500, "Stripe API key is not configured.");
  }
  return env.STRIPE_SECRET_KEY;
}

export function requireStripeWebhookSecret(env: Env): string {
  if (!env.STRIPE_WEBHOOK_SECRET) {
    throw new HttpError(401, "Missing Stripe signature.");
  }
  return env.STRIPE_WEBHOOK_SECRET;
}

export function requireOpenAISecret(env: Env): string {
  if (!env.OPENAI_API_KEY) {
    throw new HttpError(500, "OpenAI is not configured.");
  }
  return env.OPENAI_API_KEY;
}

export function configuredOpenAIModel(value: string | undefined, fallback: string, label: string): string {
  const model = (value || fallback).trim();
  if (!OPENAI_MODEL_NAME_PATTERN.test(model)) {
    throw new HttpError(500, `${label} is not configured safely.`);
  }
  return model;
}

export function numericEnv(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function requireProductionHTTPSURL(value: string, name: string): void {
  const url = parseConfiguredURL(value, name);
  if (url.protocol !== "https:") {
    throw new HttpError(500, `${name} must use https://.`);
  }
  if (url.hostname.endsWith("example.com")) {
    throw new HttpError(500, `${name} must not use example.com.`);
  }
}

function parseConfiguredURL(value: string, name: string): URL {
  try {
    return new URL(value);
  } catch {
    throw new HttpError(500, `${name} must be a valid URL.`);
  }
}

function isASCIIString(value: string): boolean {
  return [...value].every((character) => character.charCodeAt(0) < 128);
}
