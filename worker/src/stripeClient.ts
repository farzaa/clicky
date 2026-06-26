import { HttpError } from "./http";
import { readBoundedResponseText, parseJSONText } from "./payloadSecurity";
import { requireStripeAPISecret } from "./runtimeConfig";
import { asRecord, stringOrNull } from "./structuredValues";

const MAX_STRIPE_API_RESPONSE_BYTES = 262_144;

export async function stripeFetch(env: Env, path: string, form: URLSearchParams): Promise<Record<string, unknown>> {
  return await stripeFetchJSON(env, path, "POST", form);
}

export async function stripeFetchJSON(
  env: Env,
  path: string,
  method: "GET" | "POST",
  form?: URLSearchParams
): Promise<Record<string, unknown>> {
  const stripeSecretKey = requireStripeAPISecret(env);
  const response = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: {
      authorization: `Bearer ${stripeSecretKey}`,
      ...(form ? { "content-type": "application/x-www-form-urlencoded" } : {}),
    },
    body: form,
  });

  if (!response.ok) {
    throw new HttpError(response.status, "Stripe request failed.");
  }
  const rawBody = await readBoundedResponseText(response, MAX_STRIPE_API_RESPONSE_BYTES, "Stripe response is too large.");
  return asRecord(parseJSONText<unknown>(rawBody, "Stripe returned invalid JSON.", 502));
}

export function stripeHostedSessionURL(value: unknown, label: string, allowedHostname: string): string {
  const urlString = stringOrNull(value);
  if (!urlString) {
    throw new HttpError(502, `Stripe did not return a ${label} URL.`);
  }

  let url: URL;
  try {
    url = new URL(urlString);
  } catch {
    throw new HttpError(502, `Stripe returned an invalid ${label} URL.`);
  }

  if (
    url.protocol !== "https:"
    || url.hostname !== allowedHostname
    || url.username
    || url.password
  ) {
    throw new HttpError(502, `Stripe returned an unsafe ${label} URL.`);
  }

  return url.toString();
}
