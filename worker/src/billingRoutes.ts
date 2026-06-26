import { recordAuditEvent } from "./auditEventStore";
import { requireUser } from "./authRoutes";
import { effectiveEntitlementStatus } from "./entitlementPolicy";
import { HttpError, jsonResponse } from "./http";
import {
  requireStripeAPISecret,
  requireStripePriceID,
  requireStripeRedirectURLs,
} from "./runtimeConfig";
import {
  stripeFetch,
  stripeHostedSessionURL,
} from "./stripeClient";

export async function createCheckoutSession(request: Request, env: Env): Promise<Response> {
  const user = await requireUser(request, env);
  const entitlementStatus = effectiveEntitlementStatus(user);
  if (entitlementStatus === "active" || entitlementStatus === "trial") {
    throw new HttpError(409, "Subscription is already active.");
  }
  const stripePriceId = requireStripePriceID(env);
  requireStripeRedirectURLs(env);
  requireStripeAPISecret(env);

  const form = new URLSearchParams();
  form.set("mode", "subscription");
  form.set("line_items[0][price]", stripePriceId);
  form.set("line_items[0][quantity]", "1");
  form.set("success_url", env.STRIPE_SUCCESS_URL!);
  form.set("cancel_url", env.STRIPE_CANCEL_URL!);
  form.set("client_reference_id", user.id);
  form.set("metadata[spider_user_id]", user.id);
  form.set("subscription_data[metadata][spider_user_id]", user.id);
  if (user.stripeCustomerId) {
    form.set("customer", user.stripeCustomerId);
  }

  await recordAuditEvent(env, user.id, "billing_checkout_started");
  const stripeResponse = await stripeFetch(env, "/v1/checkout/sessions", form);
  const checkoutURL = stripeHostedSessionURL(stripeResponse.url, "Checkout", "checkout.stripe.com");

  return jsonResponse({
    url: checkoutURL,
  });
}

export async function createBillingPortalSession(request: Request, env: Env): Promise<Response> {
  const user = await requireUser(request, env);
  if (!user.stripeCustomerId) {
    throw new HttpError(409, "User does not have a Stripe customer yet.");
  }
  requireStripeRedirectURLs(env);
  requireStripeAPISecret(env);

  const form = new URLSearchParams();
  form.set("customer", user.stripeCustomerId);
  form.set("return_url", env.STRIPE_SUCCESS_URL!);

  await recordAuditEvent(env, user.id, "billing_portal_started");
  const stripeResponse = await stripeFetch(env, "/v1/billing_portal/sessions", form);
  const portalURL = stripeHostedSessionURL(stripeResponse.url, "billing portal", "billing.stripe.com");

  return jsonResponse({
    url: portalURL,
  });
}
