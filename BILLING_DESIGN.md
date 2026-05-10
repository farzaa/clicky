# Billing design for vibe-id

How to add paid tiers / pay-per-use on top of the existing vibe-id auth + quota system. All schema and code lives on **vibe-id** (the central identity service), not on per-project workers — same pattern as quotas.

This is a design, not implementation. Apply piece-by-piece when you actually want to charge.

---

## Goals

1. Per-user **balance** in cents (or your unit). Users top up via Stripe; usage decrements.
2. Per-endpoint **price** so different endpoints can cost different amounts. Per-project overrides if a project wants to subsidize an endpoint or charge a multiplier.
3. **Free tier** preserved: a daily allowance every user gets, paid usage only kicks in once they exceed it.
4. **Fail-closed when broke** but with a friendly error so the user knows to top up.
5. **Stripe Checkout** for the top-up flow — no card data ever touches your code.
6. **Open-source friendly**: project devs forking vibe-id can run their own Stripe, or just delete the billing tables and run free.

---

## Schema (additions to vibe-id D1)

### `users` — add balance + tier

```sql
ALTER TABLE users ADD COLUMN balance_cents INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN tier TEXT NOT NULL DEFAULT 'free';
   -- 'free' | 'paid' (or 'starter' / 'pro' / etc if you tier later)
ALTER TABLE users ADD COLUMN stripe_customer_id TEXT;
   -- nullable; only set after first top-up
```

### `endpoint_pricing` — what each endpoint costs

```sql
CREATE TABLE endpoint_pricing (
  project_id TEXT,                 -- NULL = applies to all projects (fallback)
  endpoint TEXT NOT NULL,
  unit_price_cents INTEGER NOT NULL,
   -- the cost per unit of `amount` from project_endpoints.amount_kind.
   -- Example: chat amount=1, price=2 cents → 2¢ per chat call.
   --          tts   amount=character_count, price=1 cent per 100 chars
   --                = price stored as 1 cent and amount divided by 100,
   --                or price stored as 0.01 cents and just multiplied.
   -- Easiest: use millicents (thousandths of a cent) for fine resolution.
  unit_size INTEGER NOT NULL DEFAULT 1,
   -- how much of `amount` constitutes one unit. For tts with charge per
   -- 100 chars, unit_size = 100.
  PRIMARY KEY (project_id, endpoint)
);

-- Default pricing examples:
INSERT INTO endpoint_pricing VALUES
  (NULL, 'chat',             20,  1),    -- 20¢ per Claude call (heavy: Opus)
                                          --  swap to 2¢ for Sonnet by setting
                                          --  per-project override below
  (NULL, 'tts',               1, 100),   -- 1¢ per 100 ElevenLabs characters
  (NULL, 'transcribe-token',  5,  1);    -- 5¢ per AssemblyAI session

-- Per-project override (e.g., Dot subsidizes chat):
INSERT INTO endpoint_pricing VALUES
  ('dot', 'chat', 5, 1);  -- 5¢ per chat just for Dot
```

### `payment_intents` — Stripe round-trip log

```sql
CREATE TABLE payment_intents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  stripe_payment_intent_id TEXT NOT NULL UNIQUE,
  amount_cents INTEGER NOT NULL,
  status TEXT NOT NULL,             -- 'pending' | 'succeeded' | 'failed' | 'canceled'
  created_at INTEGER NOT NULL,
  completed_at INTEGER,
  webhook_received_at INTEGER,      -- NULL until Stripe webhook lands
  FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### `daily_free_tier` — what each tier gets free per day

Optional but cleaner than hardcoding. Use the existing per-user `daily_*_limit` columns if simpler — but those are global limits, not free-tier specific. Up to you.

```sql
CREATE TABLE tier_limits (
  tier TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  daily_free_units INTEGER NOT NULL,
  PRIMARY KEY (tier, endpoint)
);

INSERT INTO tier_limits VALUES
  ('free', 'chat',              50,   100),    -- 50 free chats/day, then pay
  ('free', 'tts',               5000, 100000), -- 5000 free TTS chars/day
  ('free', 'transcribe-token',  10,   100),
  ('paid', 'chat',              500,  100000), -- much higher caps for paid
  ('paid', 'tts',               100000, 1000000);
```

(The second number is a hard upper bound regardless of balance — abuse protection.)

---

## The gating logic

`assertQuotaAndBilling(env, user, project, endpoint, amount)`:

```ts
// 1. Hard daily cap (abuse protection — applies whether free or paid)
const dailyHardLimit = lookupTierHardLimit(user.tier, endpoint);
const usedToday = sumUsageEventsLast24h(user.id, endpoint);
if (usedToday + amount > dailyHardLimit) {
  return { ok: false, response: jsonResponse({ error: "daily_hard_limit" }, 429) };
}

// 2. Free-tier daily allowance (zero cost up to this number)
const dailyFreeUnits = lookupTierFreeUnits(user.tier, endpoint);
const stillFreeUnits = Math.max(0, dailyFreeUnits - usedToday);
const billableUnits = Math.max(0, amount - stillFreeUnits);

// 3. If the request is fully within free tier, pass without charging
if (billableUnits === 0) {
  return { ok: true, chargeCents: 0 };
}

// 4. Compute charge for the over-allowance portion
const pricing = lookupPricing(project, endpoint);
const chargeCents = Math.ceil(billableUnits / pricing.unit_size) * pricing.unit_price_cents;

// 5. Check balance (fail closed if broke)
if (user.balance_cents < chargeCents) {
  return {
    ok: false,
    response: jsonResponse({
      error: "insufficient_balance",
      balance_cents: user.balance_cents,
      cost_cents: chargeCents,
      top_up_url: "https://account.vibe-research.net/billing"
    }, 402)
  };
}

return { ok: true, chargeCents };
```

After the upstream call succeeds:

```ts
// 6. Decrement balance (atomic UPDATE; D1 doesn't have transactions but
//    the single statement is atomic)
await env.DB.prepare(
  "UPDATE users SET balance_cents = balance_cents - ? WHERE id = ?"
).bind(chargeCents, user.id).run();

// 7. Record the usage event with cost_cents (extends the existing schema)
await env.DB.prepare(
  "INSERT INTO usage_events (user_id, project_id, endpoint, amount, cost_cents, status_code, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
).bind(user.id, project, endpoint, amount, chargeCents, statusCode, now).run();
```

The fact that `chargeCents` is computed from `(amount, pricing)` means the same `usage_events` row stores both the metric AND the dollar cost — admin views can sum either.

---

## Stripe integration

### Server side — vibe-id endpoints

```
POST /v1/billing/checkout-session   bearer
  Body: { amount_cents: 500 }       // user picks $5, $20, $50 from a UI
  → { stripe_session_url: "https://checkout.stripe.com/c/pay/cs_..." }

POST /v1/billing/webhook            no auth — Stripe-signature header verified
  ← Stripe POSTs payment_intent.succeeded etc.
  → applies balance, marks payment_intent.status='succeeded'

GET  /v1/billing/balance            bearer
  → { balance_cents, recent_topups: [...] }
```

### Worker code (sketch)

```ts
// /v1/billing/checkout-session
async function handleCreateCheckoutSession(request, env) {
  const user = await authenticateBearer(request, env);
  const { amount_cents } = await request.json();

  // Get-or-create Stripe customer
  let customerId = user.stripe_customer_id;
  if (!customerId) {
    const customer = await stripeFetch(env, "POST", "customers", {
      email: user.email,
      metadata: { vibe_id_user_id: user.id }
    });
    customerId = customer.id;
    await env.DB.prepare("UPDATE users SET stripe_customer_id = ? WHERE id = ?")
      .bind(customerId, user.id).run();
  }

  // Create Checkout Session — pre-paid balance pattern (not subscription)
  const session = await stripeFetch(env, "POST", "checkout/sessions", {
    customer: customerId,
    mode: "payment",
    payment_method_types: ["card"],
    line_items: [{
      price_data: {
        currency: "usd",
        product_data: { name: `Vibe Research credits ($${amount_cents / 100})` },
        unit_amount: amount_cents,
      },
      quantity: 1,
    }],
    success_url: env.WEBSITE_PUBLIC_URL + "/billing/success?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: env.WEBSITE_PUBLIC_URL + "/billing/canceled",
    metadata: { vibe_id_user_id: user.id, amount_cents: amount_cents.toString() },
  });

  // Log the intent so we can match the webhook
  await env.DB.prepare(
    "INSERT INTO payment_intents (user_id, stripe_payment_intent_id, amount_cents, status, created_at) VALUES (?, ?, ?, 'pending', ?)"
  ).bind(user.id, session.payment_intent, amount_cents, now()).run();

  return jsonResponse({ stripe_session_url: session.url });
}

// /v1/billing/webhook — receives Stripe events
async function handleStripeWebhook(request, env) {
  const signatureHeader = request.headers.get("stripe-signature");
  const rawBody = await request.text();
  const event = await verifyStripeSignature(rawBody, signatureHeader, env.STRIPE_WEBHOOK_SECRET);
  if (!event) return new Response("invalid signature", { status: 400 });

  if (event.type === "payment_intent.succeeded") {
    const pi = event.data.object;
    const userId = parseInt(pi.metadata.vibe_id_user_id, 10);
    const amountCents = parseInt(pi.metadata.amount_cents, 10);

    // Idempotency — check we haven't already processed this PI
    const existing = await env.DB.prepare(
      "SELECT status FROM payment_intents WHERE stripe_payment_intent_id = ?"
    ).bind(pi.id).first();
    if (existing?.status === "succeeded") return new Response("already processed", { status: 200 });

    // Credit the balance + mark paid
    await env.DB.prepare(
      "UPDATE users SET balance_cents = balance_cents + ?, tier = 'paid' WHERE id = ?"
    ).bind(amountCents, userId).run();

    await env.DB.prepare(
      "UPDATE payment_intents SET status = 'succeeded', completed_at = ?, webhook_received_at = ? WHERE stripe_payment_intent_id = ?"
    ).bind(now(), now(), pi.id).run();
  }

  return new Response("ok", { status: 200 });
}
```

### Stripe webhook URL

`https://api.accounts.vibe-research.net/v1/billing/webhook` — configure in the Stripe dashboard, listen for `payment_intent.succeeded` (and optionally `.payment_failed`, `.canceled`).

---

## Account dashboard — added section

Append to `website/research-lab/account.html` (and any per-project copy):

```html
<div class="card">
  <div class="row">
    <div>
      <div class="label">Balance</div>
      <div style="font-size: 28px; font-weight: 700;">
        $<span id="balanceDollars">0.00</span>
      </div>
    </div>
    <button id="topUpButton" class="button">Add credits</button>
  </div>
</div>

<script>
  document.getElementById("topUpButton").addEventListener("click", async () => {
    const amount = prompt("How much? (USD)", "5");
    const cents = Math.round(parseFloat(amount) * 100);
    const response = await fetch(VIBE_ID_BASE_URL + "/v1/billing/checkout-session", {
      method: "POST",
      headers: { authorization: "Bearer " + token, "content-type": "application/json" },
      body: JSON.stringify({ amount_cents: cents }),
    });
    const { stripe_session_url } = await response.json();
    window.location.href = stripe_session_url;
  });
</script>
```

After the user pays, Stripe redirects to `success_url` and the webhook (independently) credits the balance. Reloading the account page shows the new balance.

---

## Open-source / fork story

Three layers, increasing in lift:

1. **No billing**: don't apply any of these migrations. Keep the existing free-quota system. This is what dot ships with today.
2. **Self-hosted Stripe**: apply the schema, set your own `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` as vibe-id secrets, configure the webhook URL in your Stripe dashboard. Your fork has its own billing.
3. **Use the official vibe-id**: anyone using `api.accounts.vibe-research.net` automatically gets your billing. They use Mark's vibe-id, Mark's Stripe account, Mark gets the money. (This is the "Stripe-for-AI" version of the story.)

The choice between 2 and 3 happens at config time — `vibeIdBaseURL` either points at your own deployed vibe-id or at the official one.

---

## What to do FIRST

If you decide to add billing, do it in this order:

1. Apply the schema migrations (users + endpoint_pricing + payment_intents + tier_limits).
2. Update `assertQuotaAndBilling` in vibe-id to do the gating logic.
3. Add `cost_cents` column to `usage_events` and start populating it.
4. Build the `/v1/billing/checkout-session` endpoint.
5. Build the Stripe webhook handler — with idempotency.
6. Add the top-up UI to the account dashboard.
7. Smoke-test with Stripe's test cards (`4242 4242 4242 4242`).
8. Switch Stripe to live mode and announce.

Each step is independently shippable. Steps 1-3 can land without 4-6 — you just hold off on charging until the UI is ready.
