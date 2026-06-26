import { recordAuditEvent } from "./auditEventStore";
import { entitlementStatusFromStripeSubscriptionStatus } from "./entitlementPolicy";
import { HttpError, jsonResponse } from "./http";
import {
  hmacSHA256Hex,
  timingSafeEqual,
} from "./identitySecurity";
import {
  parseJSONText,
  readBoundedRequestText,
} from "./payloadSecurity";
import { requireStripeWebhookSecret } from "./runtimeConfig";
import { stripeFetchJSON } from "./stripeClient";
import {
  markStripeEventProcessed,
  releaseStripeEventReservation,
  reserveStripeEvent,
} from "./stripeEventStore";
import {
  asRecord,
  numberOrNull,
  stringOrNull,
  stringOrUndefined,
} from "./structuredValues";

interface StripeWebhookEvent {
  id?: unknown;
  type?: unknown;
  data?: unknown;
}

interface StripeSubscriptionSnapshot {
  stripeCustomerId: string;
  stripeSubscriptionId?: string;
  stripeStatus: string;
  currentPeriodEnd: number | null;
  cancelAtPeriodEnd: number;
  metadataUserId?: string;
}

const MAX_STRIPE_WEBHOOK_BYTES = 262_144;

export async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  const rawBody = await readBoundedRequestText(request, MAX_STRIPE_WEBHOOK_BYTES, "Stripe webhook payload is too large.");
  await verifyStripeSignature(request, env, rawBody);

  const event = parseJSONText<StripeWebhookEvent>(rawBody, "Invalid Stripe webhook body.");
  const eventId = stringOrNull(event.id);
  const eventType = stringOrNull(event.type);
  const object = asRecord(asRecord(event.data).object);

  if (!eventType) {
    throw new HttpError(400, "Invalid Stripe event type.");
  }

  if (eventId) {
    const reservation = await reserveStripeEvent(env, eventId, eventType);
    if (reservation === "duplicate") {
      return jsonResponse({ received: true, duplicate: true });
    }
  }

  try {
    await applyStripeEvent(env, eventType, object);
    if (eventId) {
      await markStripeEventProcessed(env, eventId);
    }
  } catch (error) {
    if (eventId) {
      await releaseStripeEventReservation(env, eventId);
    }
    throw error;
  }

  return jsonResponse({ received: true });
}

async function applyStripeEvent(env: Env, eventType: string, object: Record<string, unknown>): Promise<void> {
  if (eventType === "checkout.session.completed") {
    const userId = stringOrUndefined(object.client_reference_id);
    const stripeCustomerId = stringOrUndefined(object.customer);
    const stripeSubscriptionId = stringOrUndefined(object.subscription);
    if (userId && stripeCustomerId && stripeSubscriptionId) {
      await env.DB.prepare(
        `UPDATE users
         SET stripe_customer_id = ?,
             stripe_subscription_id = ?,
             updated_at = unixepoch()
         WHERE id = ?`
      ).bind(stripeCustomerId, stripeSubscriptionId, userId).run();
      await recordAuditEvent(env, userId, "billing_checkout_completed");
    }
  }

  if (eventType.startsWith("customer.subscription.")) {
    await applyStripeSubscriptionState(env, subscriptionSnapshotFromStripeObject(object));
  }

  if (isStripeInvoiceSubscriptionSyncEvent(eventType)) {
    await applyStripeInvoiceSubscriptionState(env, object);
  }
}

function subscriptionSnapshotFromStripeObject(object: Record<string, unknown>): StripeSubscriptionSnapshot | null {
  const stripeCustomerId = stringOrUndefined(object.customer);
  const stripeStatus = stringOrUndefined(object.status);
  if (!stripeCustomerId || !stripeStatus) {
    return null;
  }

  return {
    stripeCustomerId,
    stripeSubscriptionId: stringOrUndefined(object.id),
    stripeStatus,
    currentPeriodEnd: numberOrNull(object.current_period_end),
    cancelAtPeriodEnd: object.cancel_at_period_end === true ? 1 : 0,
    metadataUserId: stringOrUndefined(asRecord(object.metadata).spider_user_id),
  };
}

function isStripeInvoiceSubscriptionSyncEvent(eventType: string): boolean {
  return eventType === "invoice.paid"
    || eventType === "invoice.payment_failed"
    || eventType === "invoice.payment_action_required";
}

async function applyStripeInvoiceSubscriptionState(
  env: Env,
  invoice: Record<string, unknown>
): Promise<void> {
  const stripeCustomerId = stringOrUndefined(invoice.customer);
  const stripeSubscriptionId = stringOrUndefined(invoice.subscription);
  if (!stripeCustomerId || !stripeSubscriptionId) {
    return;
  }

  const subscription = await retrieveStripeSubscription(env, stripeSubscriptionId);
  const snapshot = subscriptionSnapshotFromStripeObject(subscription);
  if (
    !snapshot
    || snapshot.stripeCustomerId !== stripeCustomerId
    || (
      snapshot.stripeSubscriptionId !== undefined
      && snapshot.stripeSubscriptionId !== stripeSubscriptionId
    )
  ) {
    return;
  }

  await applyStripeSubscriptionState(env, {
    ...snapshot,
    stripeSubscriptionId,
  });
}

async function applyStripeSubscriptionState(
  env: Env,
  subscription: StripeSubscriptionSnapshot | null
): Promise<void> {
  if (!subscription) {
    return;
  }

  const entitlementStatus = entitlementStatusFromStripeSubscriptionStatus(subscription.stripeStatus);
  if (subscription.metadataUserId) {
    await env.DB.prepare(
      `UPDATE users
       SET stripe_customer_id = COALESCE(stripe_customer_id, ?),
           stripe_subscription_id = COALESCE(?, stripe_subscription_id),
           subscription_status = ?,
           subscription_current_period_end = ?,
           cancel_at_period_end = ?,
           entitlement_status = ?,
           updated_at = unixepoch()
       WHERE id = ?
         AND (
           stripe_customer_id IS NULL
           OR stripe_customer_id = ?
         )`
    ).bind(
      subscription.stripeCustomerId,
      subscription.stripeSubscriptionId || null,
      subscription.stripeStatus,
      subscription.currentPeriodEnd,
      subscription.cancelAtPeriodEnd,
      entitlementStatus,
      subscription.metadataUserId,
      subscription.stripeCustomerId
    ).run();
  } else {
    await env.DB.prepare(
      `UPDATE users
       SET stripe_subscription_id = COALESCE(?, stripe_subscription_id),
           subscription_status = ?,
           subscription_current_period_end = ?,
           cancel_at_period_end = ?,
           entitlement_status = ?,
           updated_at = unixepoch()
       WHERE stripe_customer_id = ?`
    ).bind(
      subscription.stripeSubscriptionId || null,
      subscription.stripeStatus,
      subscription.currentPeriodEnd,
      subscription.cancelAtPeriodEnd,
      entitlementStatus,
      subscription.stripeCustomerId
    ).run();
  }
}

async function retrieveStripeSubscription(
  env: Env,
  stripeSubscriptionId: string
): Promise<Record<string, unknown>> {
  return await stripeFetchJSON(env, `/v1/subscriptions/${encodeURIComponent(stripeSubscriptionId)}`, "GET");
}

async function verifyStripeSignature(request: Request, env: Env, rawBody: string): Promise<void> {
  const signatureHeader = request.headers.get("stripe-signature");
  const webhookSecret = requireStripeWebhookSecret(env);
  if (!signatureHeader) {
    throw new HttpError(401, "Missing Stripe signature.");
  }

  const signatureParts = signatureHeader.split(",").map((part) => {
    const [key, value] = part.split("=");
    return { key, value };
  });
  const timestamp = signatureParts.find((part) => part.key === "t")?.value;
  const signatures = signatureParts
    .filter((part) => part.key === "v1" && part.value)
    .map((part) => part.value);

  if (!timestamp || signatures.length === 0) {
    throw new HttpError(401, "Invalid Stripe signature.");
  }

  const timestampNumber = Number(timestamp);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(timestampNumber) || Math.abs(now - timestampNumber) > 300) {
    throw new HttpError(401, "Expired Stripe signature.");
  }

  const signedPayload = `${timestamp}.${rawBody}`;
  const expected = await hmacSHA256Hex(webhookSecret, signedPayload);
  let signatureMatches = false;
  for (const signature of signatures) {
    signatureMatches = (await timingSafeEqual(expected, signature)) || signatureMatches;
  }

  if (!signatureMatches) {
    throw new HttpError(401, "Invalid Stripe signature.");
  }
}
