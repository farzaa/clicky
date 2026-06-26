import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerWorkerBillingRuntimeArchitectureAssertions({ test, workerRoot }) {
  test("worker Stripe event store keeps webhook idempotency writes outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const webhookRoutesSource = readFileSync(path.join(workerRoot, "src", "stripeWebhookRoutes.ts"), "utf8");
    const storeSource = readFileSync(path.join(workerRoot, "src", "stripeEventStore.ts"), "utf8");

    assert.match(webhookRoutesSource, /from "\.\/stripeEventStore"/);
    assert.match(storeSource, /export type StripeEventReservation = "reserved" \| "duplicate"/);
    assert.match(storeSource, /export async function reserveStripeEvent/);
    assert.match(storeSource, /export async function markStripeEventProcessed/);
    assert.match(storeSource, /export async function releaseStripeEventReservation/);
    assert.match(storeSource, /INSERT OR IGNORE INTO stripe_events/);
    assert.match(storeSource, /SET processed_at = unixepoch\(\)/);
    assert.match(storeSource, /processing_started_at < unixepoch\(\) - 300/);
    assert.doesNotMatch(indexSource, /from "\.\/stripeEventStore"/);
    assert.doesNotMatch(indexSource, /INSERT OR IGNORE INTO stripe_events/);
    assert.doesNotMatch(indexSource, /UPDATE stripe_events/);
    assert.doesNotMatch(indexSource, /SELECT processed_at, processing_started_at/);
    assert.doesNotMatch(indexSource, /type StripeEventReservation =/);
    assert.doesNotMatch(indexSource, /function reserveStripeEvent\(/);
    assert.doesNotMatch(indexSource, /function markStripeEventProcessed\(/);
    assert.doesNotMatch(indexSource, /function releaseStripeEventReservation\(/);
  });

  test("worker Stripe client keeps HTTP and hosted URL policy outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const billingRoutesSource = readFileSync(path.join(workerRoot, "src", "billingRoutes.ts"), "utf8");
    const webhookRoutesSource = readFileSync(path.join(workerRoot, "src", "stripeWebhookRoutes.ts"), "utf8");
    const clientSource = readFileSync(path.join(workerRoot, "src", "stripeClient.ts"), "utf8");

    assert.match(billingRoutesSource, /from "\.\/stripeClient"/);
    assert.match(webhookRoutesSource, /from "\.\/stripeClient"/);
    assert.match(clientSource, /export async function stripeFetch/);
    assert.match(clientSource, /export async function stripeFetchJSON/);
    assert.match(clientSource, /export function stripeHostedSessionURL/);
    assert.match(clientSource, /const MAX_STRIPE_API_RESPONSE_BYTES = 262_144/);
    assert.match(clientSource, /readBoundedResponseText\(response, MAX_STRIPE_API_RESPONSE_BYTES/);
    assert.match(clientSource, /requireStripeAPISecret\(env\)/);
    assert.match(clientSource, /url\.protocol !== "https:"/);
    assert.match(clientSource, /url\.hostname !== allowedHostname/);
    assert.match(clientSource, /url\.username/);
    assert.match(clientSource, /url\.password/);
    assert.doesNotMatch(indexSource, /from "\.\/stripeClient"/);
    assert.doesNotMatch(indexSource, /const MAX_STRIPE_API_RESPONSE_BYTES/);
    assert.doesNotMatch(indexSource, /function stripeFetch\(/);
    assert.doesNotMatch(indexSource, /function stripeFetchJSON\(/);
    assert.doesNotMatch(indexSource, /function stripeHostedSessionURL\(/);
    assert.doesNotMatch(indexSource, /Stripe response is too large/);
    assert.doesNotMatch(indexSource, /Stripe returned invalid JSON/);
    assert.doesNotMatch(indexSource, /Stripe returned an unsafe/);
  });

  test("worker billing routes keep checkout and portal flow outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const routesSource = readFileSync(path.join(workerRoot, "src", "workerRoutes.ts"), "utf8");
    const billingRoutesSource = readFileSync(path.join(workerRoot, "src", "billingRoutes.ts"), "utf8");

    assert.match(routesSource, /from "\.\/billingRoutes"/);
    assert.match(routesSource, /createCheckoutSession\(request, env\)/);
    assert.match(routesSource, /createBillingPortalSession\(request, env\)/);
    assert.match(billingRoutesSource, /export async function createCheckoutSession/);
    assert.match(billingRoutesSource, /export async function createBillingPortalSession/);
    assert.match(billingRoutesSource, /effectiveEntitlementStatus\(user\)/);
    assert.match(billingRoutesSource, /requireStripePriceID\(env\)/);
    assert.match(billingRoutesSource, /requireStripeRedirectURLs\(env\)/);
    assert.match(billingRoutesSource, /requireStripeAPISecret\(env\)/);
    assert.match(billingRoutesSource, /recordAuditEvent\(env, user\.id, "billing_checkout_started"\)/);
    assert.match(billingRoutesSource, /recordAuditEvent\(env, user\.id, "billing_portal_started"\)/);
    assert.match(
      billingRoutesSource,
      /stripeHostedSessionURL\(stripeResponse\.url, "Checkout", "checkout\.stripe\.com"\)/
    );
    assert.match(
      billingRoutesSource,
      /stripeHostedSessionURL\(stripeResponse\.url, "billing portal", "billing\.stripe\.com"\)/
    );
    assert.doesNotMatch(indexSource, /function createCheckoutSession\(/);
    assert.doesNotMatch(indexSource, /function createBillingPortalSession\(/);
    assert.doesNotMatch(indexSource, /billing_checkout_started/);
    assert.doesNotMatch(indexSource, /billing_portal_started/);
    assert.doesNotMatch(indexSource, /checkout\.stripe\.com/);
    assert.doesNotMatch(indexSource, /billing\.stripe\.com/);
    assert.doesNotMatch(indexSource, /from "\.\/billingRoutes"/);
  });

  test("worker Realtime route keeps OpenAI voice client-secret flow outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const routesSource = readFileSync(path.join(workerRoot, "src", "workerRoutes.ts"), "utf8");
    const realtimeRoutesSource = readFileSync(path.join(workerRoot, "src", "realtimeRoutes.ts"), "utf8");

    assert.match(routesSource, /from "\.\/realtimeRoutes"/);
    assert.match(routesSource, /createRealtimeClientSecret\(request, env\)/);
    assert.match(realtimeRoutesSource, /export async function createRealtimeClientSecret/);
    assert.match(realtimeRoutesSource, /requirePaidUser\(request, env\)/);
    assert.match(realtimeRoutesSource, /requireOpenAISecret\(env\)/);
    assert.match(realtimeRoutesSource, /configuredOpenAIModel\(env\.OPENAI_REALTIME_MODEL/);
    assert.match(realtimeRoutesSource, /consumeRequestRateLimits\(request, env, "realtime"/);
    assert.match(realtimeRoutesSource, /consumeQuota\(env, user\.id, "realtime"/);
    assert.match(realtimeRoutesSource, /recordAuditEvent\(env, user\.id, "realtime_client_secret_requested"\)/);
    assert.match(realtimeRoutesSource, /https:\/\/api\.openai\.com\/v1\/realtime\/client_secrets/);
    assert.match(realtimeRoutesSource, /"OpenAI-Safety-Identifier": user\.emailHash/);
    assert.match(realtimeRoutesSource, /readBoundedResponseText\(\s*openAIResponse,\s*MAX_REALTIME_SECRET_RESPONSE_BYTES/s);
    assert.match(realtimeRoutesSource, /OPENAI_CLIENT_SECRET_VALUE_PATTERN/);
    assert.match(realtimeRoutesSource, /return jsonResponse\(realtimeClientSecretPayload\(responseText, realtimeModel\)\)/);
    assert.match(realtimeRoutesSource, /client_secret:/);
    assert.match(realtimeRoutesSource, /model: realtimeModel/);
    assert.doesNotMatch(indexSource, /function createRealtimeClientSecret\(/);
    assert.doesNotMatch(indexSource, /function realtimeInstructions\(/);
    assert.doesNotMatch(indexSource, /function realtimeClientSecretPayload\(/);
    assert.doesNotMatch(indexSource, /MAX_REALTIME_SECRET_RESPONSE_BYTES/);
    assert.doesNotMatch(indexSource, /OPENAI_CLIENT_SECRET_VALUE_PATTERN/);
    assert.doesNotMatch(indexSource, /realtime_client_secret_requested/);
    assert.doesNotMatch(indexSource, /api\.openai\.com\/v1\/realtime\/client_secrets/);
    assert.doesNotMatch(indexSource, /from "\.\/realtimeRoutes"/);
  });

  test("worker Stripe webhook route keeps signature, idempotency, and entitlement reconciliation outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const routesSource = readFileSync(path.join(workerRoot, "src", "workerRoutes.ts"), "utf8");
    const webhookRoutesSource = readFileSync(path.join(workerRoot, "src", "stripeWebhookRoutes.ts"), "utf8");

    assert.match(routesSource, /from "\.\/stripeWebhookRoutes"/);
    assert.match(routesSource, /handleStripeWebhook\(request, env\)/);
    assert.match(webhookRoutesSource, /export async function handleStripeWebhook/);
    assert.match(webhookRoutesSource, /readBoundedRequestText\(request, MAX_STRIPE_WEBHOOK_BYTES/);
    assert.match(webhookRoutesSource, /verifyStripeSignature\(request, env, rawBody\)/);
    assert.match(webhookRoutesSource, /reserveStripeEvent\(env, eventId, eventType\)/);
    assert.match(webhookRoutesSource, /markStripeEventProcessed\(env, eventId\)/);
    assert.match(webhookRoutesSource, /releaseStripeEventReservation\(env, eventId\)/);
    assert.match(webhookRoutesSource, /billing_checkout_completed/);
    assert.match(webhookRoutesSource, /entitlementStatusFromStripeSubscriptionStatus/);
    assert.match(webhookRoutesSource, /stripeFetchJSON\(env, `\/v1\/subscriptions\/\$\{encodeURIComponent\(stripeSubscriptionId\)\}`/);
    assert.match(webhookRoutesSource, /requireStripeWebhookSecret\(env\)/);
    assert.match(webhookRoutesSource, /hmacSHA256Hex\(webhookSecret, signedPayload\)/);
    assert.match(webhookRoutesSource, /timingSafeEqual\(expected, signature\)/);
    assert.match(webhookRoutesSource, /UPDATE users/);
    assert.match(webhookRoutesSource, /subscription_current_period_end/);
    assert.doesNotMatch(indexSource, /function handleStripeWebhook\(/);
    assert.doesNotMatch(indexSource, /function applyStripeEvent\(/);
    assert.doesNotMatch(indexSource, /function verifyStripeSignature\(/);
    assert.doesNotMatch(indexSource, /MAX_STRIPE_WEBHOOK_BYTES/);
    assert.doesNotMatch(indexSource, /requireStripeWebhookSecret/);
    assert.doesNotMatch(indexSource, /reserveStripeEvent/);
    assert.doesNotMatch(indexSource, /billing_checkout_completed/);
    assert.doesNotMatch(indexSource, /subscription_current_period_end/);
    assert.doesNotMatch(indexSource, /from "\.\/stripeWebhookRoutes"/);
  });

  test("worker operational retention store keeps scheduled cleanup outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const storeSource = readFileSync(path.join(workerRoot, "src", "operationalRetentionStore.ts"), "utf8");

    assert.match(indexSource, /from "\.\/operationalRetentionStore"/);
    assert.match(indexSource, /ctx\.waitUntil\(pruneOperationalRows\(env\)\)/);
    assert.match(storeSource, /export async function pruneOperationalRows/);
    assert.match(storeSource, /DELETE FROM magic_links/);
    assert.match(storeSource, /DELETE FROM sessions/);
    assert.match(storeSource, /DELETE FROM usage_counters/);
    assert.match(storeSource, /DELETE FROM rate_counters/);
    assert.match(storeSource, /DELETE FROM audit_events/);
    assert.match(storeSource, /DELETE FROM stripe_events/);
    assert.match(storeSource, /const MAGIC_LINK_RETENTION_SECONDS = 7 \* DAY_IN_SECONDS/);
    assert.match(storeSource, /const SESSION_RETENTION_SECONDS = 90 \* DAY_IN_SECONDS/);
    assert.match(storeSource, /const STRIPE_EVENT_RETENTION_SECONDS = 180 \* DAY_IN_SECONDS/);
    assert.doesNotMatch(indexSource, /DELETE FROM magic_links/);
    assert.doesNotMatch(indexSource, /DELETE FROM sessions/);
    assert.doesNotMatch(indexSource, /DELETE FROM usage_counters/);
    assert.doesNotMatch(indexSource, /DELETE FROM rate_counters/);
    assert.doesNotMatch(indexSource, /DELETE FROM audit_events/);
    assert.doesNotMatch(indexSource, /DELETE FROM stripe_events/);
    assert.doesNotMatch(indexSource, /const MAGIC_LINK_RETENTION_SECONDS/);
    assert.doesNotMatch(indexSource, /function dayStringDaysAgo/);
  });
}
