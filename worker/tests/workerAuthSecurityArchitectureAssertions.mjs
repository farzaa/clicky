import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerWorkerAuthSecurityArchitectureAssertions({ test, workerRoot }) {
  test("worker identity security stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const requestValidationSource = readFileSync(path.join(workerRoot, "src", "guideRequestValidation.ts"), "utf8");
    const identitySecuritySource = readFileSync(path.join(workerRoot, "src", "identitySecurity.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/identitySecurity"/);
    assert.match(requestValidationSource, /from "\.\/identitySecurity"/);
    assert.match(identitySecuritySource, /export async function sessionTokenHashFromRequest/);
    assert.match(identitySecuritySource, /export async function requiredDeviceHashFromRequest/);
    assert.match(identitySecuritySource, /export function deviceIdentifierFromRequest/);
    assert.match(identitySecuritySource, /export function clientIPAddressFromRequest/);
    assert.match(identitySecuritySource, /export function magicLinkTokenFromURL/);
    assert.match(identitySecuritySource, /export const MAX_DEVICE_IDENTIFIER_CHARS = 128/);
    assert.match(identitySecuritySource, /export async function sha256Hex/);
    assert.match(identitySecuritySource, /export async function hmacSHA256Hex/);
    assert.match(identitySecuritySource, /export async function timingSafeEqual/);
    assert.match(identitySecuritySource, /X-Spider-Device-ID/);
    assert.match(identitySecuritySource, /CF-Connecting-IP/);
    assert.match(identitySecuritySource, /authHeader\.startsWith\("Bearer "\)/);
    assert.match(identitySecuritySource, /queryEntries\.length !== 1/);
    assert.doesNotMatch(indexSource, /function sessionTokenFromRequest\(/);
    assert.doesNotMatch(indexSource, /function deviceIdentifierFromRequest\(/);
    assert.doesNotMatch(indexSource, /function magicLinkTokenFromURL\(/);
    assert.doesNotMatch(indexSource, /function timingSafeEqual\(/);
  });

  test("worker runtime configuration keeps secret and URL policy outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const billingRoutesSource = readFileSync(path.join(workerRoot, "src", "billingRoutes.ts"), "utf8");
    const realtimeRoutesSource = readFileSync(path.join(workerRoot, "src", "realtimeRoutes.ts"), "utf8");
    const visionGuideRoutesSource = readFileSync(path.join(workerRoot, "src", "visionGuideRoutes.ts"), "utf8");
    const runtimeConfigSource = readFileSync(path.join(workerRoot, "src", "runtimeConfig.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/runtimeConfig"/);
    assert.match(billingRoutesSource, /from "\.\/runtimeConfig"/);
    assert.match(realtimeRoutesSource, /from "\.\/runtimeConfig"/);
    assert.match(visionGuideRoutesSource, /from "\.\/runtimeConfig"/);
    assert.match(runtimeConfigSource, /export function normalizeEmail/);
    assert.match(runtimeConfigSource, /export async function emailHashForStorage/);
    assert.match(runtimeConfigSource, /export function requireMagicLinkDelivery/);
    assert.match(runtimeConfigSource, /export function magicLinkConfirmURL/);
    assert.match(runtimeConfigSource, /export function magicLinkDeepLinkURL/);
    assert.match(runtimeConfigSource, /export function requireStripeRedirectURLs/);
    assert.match(runtimeConfigSource, /export function requireStripeAPISecret/);
    assert.match(runtimeConfigSource, /export function requireStripeWebhookSecret/);
    assert.match(runtimeConfigSource, /export function requireOpenAISecret/);
    assert.match(runtimeConfigSource, /export function configuredOpenAIModel/);
    assert.match(runtimeConfigSource, /export function numericEnv/);
    assert.match(runtimeConfigSource, /const EMAIL_PATTERN/);
    assert.match(runtimeConfigSource, /const OPENAI_MODEL_NAME_PATTERN/);
    assert.match(runtimeConfigSource, /APP_LOGIN_DEEP_LINK_URL must be spider:\/\/auth\/confirm/);
    assert.match(runtimeConfigSource, /must not use example\.com/);
    assert.match(runtimeConfigSource, /dev-email:/);
    assert.doesNotMatch(indexSource, /from "\.\/runtimeConfig"/);
    assert.doesNotMatch(indexSource, /function normalizeEmail\(/);
    assert.doesNotMatch(indexSource, /function emailHashForStorage\(/);
    assert.doesNotMatch(indexSource, /function requireMagicLinkDelivery\(/);
    assert.doesNotMatch(indexSource, /function magicLinkConfirmURL\(/);
    assert.doesNotMatch(indexSource, /function magicLinkDeepLinkURL\(/);
    assert.doesNotMatch(indexSource, /function requireStripeRedirectURLs\(/);
    assert.doesNotMatch(indexSource, /function requireOpenAISecret\(/);
    assert.doesNotMatch(indexSource, /const EMAIL_PATTERN/);
    assert.doesNotMatch(indexSource, /const OPENAI_MODEL_NAME_PATTERN/);
  });

  test("worker entitlement policy stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const webhookRoutesSource = readFileSync(path.join(workerRoot, "src", "stripeWebhookRoutes.ts"), "utf8");
    const policySource = readFileSync(path.join(workerRoot, "src", "entitlementPolicy.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/entitlementPolicy"/);
    assert.match(webhookRoutesSource, /from "\.\/entitlementPolicy"/);
    assert.match(policySource, /export function effectiveEntitlementStatus/);
    assert.match(policySource, /export function entitlementStatusFromStripeSubscriptionStatus/);
    assert.match(policySource, /subscriptionStatus === "canceled"/);
    assert.match(policySource, /subscriptionCurrentPeriodEnd > Math\.floor\(Date\.now\(\) \/ 1000\)/);
    assert.match(policySource, /case "trialing":/);
    assert.doesNotMatch(indexSource, /from "\.\/entitlementPolicy"/);
    assert.doesNotMatch(indexSource, /function effectiveEntitlementStatus\(/);
    assert.doesNotMatch(indexSource, /function entitlementStatusFromStripeSubscriptionStatus\(/);
  });

  test("worker auth session store keeps D1 auth queries outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const storeSource = readFileSync(path.join(workerRoot, "src", "authSessionStore.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/authSessionStore"/);
    assert.match(storeSource, /export async function findAuthenticatedUserBySession/);
    assert.match(storeSource, /export async function upsertUserByEmailHash/);
    assert.match(storeSource, /export async function createMagicLink/);
    assert.match(storeSource, /export async function findUsableMagicLinkByHash/);
    assert.match(storeSource, /export async function consumeActiveMagicLinkByHash/);
    assert.match(storeSource, /export async function createDeviceBoundSession/);
    assert.match(storeSource, /JOIN users ON users\.id = sessions\.user_id/);
    assert.match(storeSource, /WHERE sessions\.token_hash = \?/);
    assert.match(storeSource, /WHERE token_hash = \?/);
    assert.doesNotMatch(indexSource, /JOIN users ON users\.id = sessions\.user_id/);
    assert.doesNotMatch(indexSource, /INSERT INTO magic_links/);
    assert.doesNotMatch(indexSource, /INSERT INTO sessions/);
    assert.doesNotMatch(indexSource, /UPDATE magic_links/);
    assert.doesNotMatch(indexSource, /UPDATE sessions\s+SET revoked_at/);
    assert.doesNotMatch(indexSource, /ON CONFLICT\(email_hash\)/);
  });

  test("worker auth route handlers stay outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const routesSource = readFileSync(path.join(workerRoot, "src", "workerRoutes.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");

    assert.match(routesSource, /from "\.\/authRoutes"/);
    assert.match(routesSource, /startMagicLinkLogin\(request, env\)/);
    assert.match(routesSource, /confirmMagicLinkLogin\(request, url, env\)/);
    assert.match(routesSource, /authLoginStatus\(request, env\)/);
    assert.match(routesSource, /revokeCurrentSession\(request, env\)/);
    assert.match(authRoutesSource, /export async function startMagicLinkLogin/);
    assert.match(authRoutesSource, /export async function confirmMagicLinkLogin/);
    assert.match(authRoutesSource, /export async function authLoginStatus/);
    assert.match(authRoutesSource, /export async function revokeCurrentSession/);
    assert.match(authRoutesSource, /export async function requireUser/);
    assert.match(authRoutesSource, /export async function requirePaidUser/);
    assert.match(authRoutesSource, /export async function consumeQuota/);
    assert.match(authRoutesSource, /export async function consumeRequestRateLimits/);
    assert.match(authRoutesSource, /readJSONRequest<\{ email\?: string \}>/);
    assert.match(authRoutesSource, /requireMagicLinkDelivery\(env\)/);
    assert.match(authRoutesSource, /DEV_RETURN_MAGIC_LINK/);
    assert.match(authRoutesSource, /escapeHTMLAttribute\(appURLString\)/);
    assert.match(authRoutesSource, /recordAuditEvent\(env, user\.id, "auth_magic_link_started"\)/);
    assert.doesNotMatch(indexSource, /function startMagicLinkLogin\(/);
    assert.doesNotMatch(indexSource, /function confirmMagicLinkLogin\(/);
    assert.doesNotMatch(indexSource, /function revokeCurrentSession\(/);
    assert.doesNotMatch(indexSource, /function requireUser\(/);
    assert.doesNotMatch(indexSource, /function requirePaidUser\(/);
    assert.doesNotMatch(indexSource, /function consumeQuota\(/);
    assert.doesNotMatch(indexSource, /function consumeRequestRateLimits\(/);
    assert.doesNotMatch(indexSource, /function requireUsableMagicLink/);
    assert.doesNotMatch(indexSource, /function magicLinkBrowserBridgeResponse\(/);
    assert.doesNotMatch(indexSource, /function sendMagicLinkEmail\(/);
    assert.doesNotMatch(indexSource, /from "\.\/authRoutes"/);
  });

  test("worker metering store keeps quota counter writes outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const storeSource = readFileSync(path.join(workerRoot, "src", "meteringStore.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/meteringStore"/);
    assert.match(storeSource, /export async function consumeDailyUserQuota/);
    assert.match(storeSource, /export async function consumeDailyActorRateLimit/);
    assert.match(storeSource, /INSERT INTO usage_counters/);
    assert.match(storeSource, /INSERT INTO rate_counters/);
    assert.match(storeSource, /ON CONFLICT\(user_id, quota_kind, day\)/);
    assert.match(storeSource, /ON CONFLICT\(actor_hash, quota_kind, day\)/);
    assert.doesNotMatch(indexSource, /INSERT INTO usage_counters/);
    assert.doesNotMatch(indexSource, /INSERT INTO rate_counters/);
    assert.doesNotMatch(indexSource, /ON CONFLICT\(user_id, quota_kind, day\)/);
    assert.doesNotMatch(indexSource, /ON CONFLICT\(actor_hash, quota_kind, day\)/);
  });

  test("worker audit event store keeps audit writes and event allowlist outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const authRoutesSource = readFileSync(path.join(workerRoot, "src", "authRoutes.ts"), "utf8");
    const billingRoutesSource = readFileSync(path.join(workerRoot, "src", "billingRoutes.ts"), "utf8");
    const realtimeRoutesSource = readFileSync(path.join(workerRoot, "src", "realtimeRoutes.ts"), "utf8");
    const visionGuideRoutesSource = readFileSync(path.join(workerRoot, "src", "visionGuideRoutes.ts"), "utf8");
    const storeSource = readFileSync(path.join(workerRoot, "src", "auditEventStore.ts"), "utf8");

    assert.match(authRoutesSource, /from "\.\/auditEventStore"/);
    assert.match(billingRoutesSource, /from "\.\/auditEventStore"/);
    assert.match(realtimeRoutesSource, /from "\.\/auditEventStore"/);
    assert.match(visionGuideRoutesSource, /from "\.\/auditEventStore"/);
    assert.match(storeSource, /export type AuditEventName/);
    assert.match(storeSource, /export async function recordAuditEvent/);
    assert.match(storeSource, /INSERT INTO audit_events/);
    assert.match(storeSource, /crypto\.randomUUID\(\)/);
    assert.match(storeSource, /"vision_guide_requested"/);
    assert.match(storeSource, /"billing_checkout_completed"/);
    assert.doesNotMatch(indexSource, /from "\.\/auditEventStore"/);
    assert.doesNotMatch(indexSource, /type AuditEventName =/);
    assert.doesNotMatch(indexSource, /function recordAuditEvent\(/);
    assert.doesNotMatch(indexSource, /INSERT INTO audit_events/);
  });
}
