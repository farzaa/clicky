import assert from "node:assert/strict";

export function registerStripeWebhookAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  stripeSignatureHeader,
}) {
  test("Stripe webhooks with missing signatures fail before touching D1", async () => {
    const env = baseEnv();
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: "evt_test", type: "checkout.session.completed", data: { object: {} } }),
      }),
      env
    );

    assert.equal(response.status, 401);
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("Stripe webhooks with expired signatures fail before touching D1", async () => {
    const env = baseEnv();
    const rawBody = JSON.stringify({
      id: "evt_expired_signature",
      type: "checkout.session.completed",
      data: { object: {} },
    });
    const expiredTimestamp = Math.floor(Date.now() / 1000) - 301;
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET, expiredTimestamp),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();

    assert.equal(response.status, 401);
    assert.equal(body.error, "Expired Stripe signature.");
    assert.equal(env.DB.executedStatements.length, 0);
  });

  test("Stripe checkout webhooks link customer and subscription without granting entitlement directly", async () => {
    const env = baseEnv();
    const rawBody = JSON.stringify({
      id: "evt_checkout_completed",
      type: "checkout.session.completed",
      data: {
        object: {
          client_reference_id: "user_test",
          customer: "cus_test",
          subscription: "sub_test",
        },
      },
    });
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();
    const statements = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.received, true);
    assert.match(statements, /INSERT OR IGNORE INTO stripe_events/);
    assert.match(statements, /SET stripe_customer_id = \?/);
    assert.match(statements, /stripe_subscription_id = \?/);
    assert.doesNotMatch(statements, /entitlement_status = 'active'/);
    assert.match(statements, /billing_checkout_completed/);
    assert.match(statements, /SET processed_at = unixepoch\(\)/);
  });

  test("Stripe checkout webhooks without a subscription do not update entitlement", async () => {
    const env = baseEnv();
    const rawBody = JSON.stringify({
      id: "evt_checkout_missing_subscription",
      type: "checkout.session.completed",
      data: {
        object: {
          client_reference_id: "user_test",
          customer: "cus_test",
        },
      },
    });
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();
    const statements = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.received, true);
    assert.match(statements, /INSERT OR IGNORE INTO stripe_events/);
    assert.doesNotMatch(statements, /SET stripe_customer_id = \?/);
    assert.doesNotMatch(statements, /billing_checkout_completed/);
    assert.doesNotMatch(statements, /entitlement_status/);
    assert.match(statements, /SET processed_at = unixepoch\(\)/);
  });

  test("Stripe active subscription webhooks grant entitlement from subscription status", async () => {
    const env = baseEnv();
    const rawBody = JSON.stringify({
      id: "evt_subscription_active",
      type: "customer.subscription.updated",
      data: {
        object: {
          id: "sub_test",
          customer: "cus_test",
          status: "active",
          current_period_end: 1_800_000_000,
          cancel_at_period_end: false,
          metadata: {
            spider_user_id: "user_test",
          },
        },
      },
    });
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();
    const statements = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.received, true);
    assert.match(statements, /stripe_customer_id = COALESCE\(stripe_customer_id, \?\)/);
    assert.match(statements, /subscription_status = \?/);
    assert.match(statements, /entitlement_status = \?/);
    assert.match(statements, /WHERE id = \?/);
    assert.match(statements, /"sub_test"/);
    assert.match(statements, /"active"/);
    assert.match(statements, /1800000000/);
    assert.match(statements, /"user_test"/);
    assert.match(statements, /SET processed_at = unixepoch\(\)/);
  });

  test("Stripe subscription webhooks do not require checkout price configuration", async () => {
    const env = baseEnv({ STRIPE_PRICE_ID: "" });
    const rawBody = JSON.stringify({
      id: "evt_subscription_without_price_config",
      type: "customer.subscription.updated",
      data: {
        object: {
          id: "sub_test",
          customer: "cus_test",
          status: "active",
          current_period_end: 1_800_000_000,
          cancel_at_period_end: false,
          metadata: {
            spider_user_id: "user_test",
          },
        },
      },
    });
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();
    const statements = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.received, true);
    assert.match(statements, /entitlement_status = \?/);
    assert.match(statements, /"active"/);
  });

  test("Stripe incomplete subscription webhooks do not grant active entitlement", async () => {
    const env = baseEnv();
    const rawBody = JSON.stringify({
      id: "evt_subscription_incomplete",
      type: "customer.subscription.updated",
      data: {
        object: {
          id: "sub_test",
          customer: "cus_test",
          status: "incomplete",
          cancel_at_period_end: false,
          metadata: {
            spider_user_id: "user_test",
          },
        },
      },
    });
    const response = await fetchWorker(
      request("/stripe/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
        },
        body: rawBody,
      }),
      env
    );
    const body = await response.json();
    const statements = JSON.stringify(env.DB.executedStatements);

    assert.equal(response.status, 200);
    assert.equal(body.received, true);
    assert.match(statements, /subscription_status = \?/);
    assert.match(statements, /entitlement_status = \?/);
    assert.match(statements, /"incomplete"/);
    assert.match(statements, /"canceled"/);
    assert.doesNotMatch(statements, /entitlement_status = 'active'/);
    assert.match(statements, /SET processed_at = unixepoch\(\)/);
  });

  test("Stripe paid invoice webhooks reconcile active subscription state", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let stripeFetchURL = "";
    let stripeFetchMethod = "";
    let stripeFetchAuthorization = "";
    globalThis.fetch = async (url, init) => {
      stripeFetchURL = String(url);
      stripeFetchMethod = init.method;
      stripeFetchAuthorization = init.headers.authorization;
      return new Response(JSON.stringify({
        id: "sub_test",
        customer: "cus_test",
        status: "active",
        current_period_end: 1_800_000_000,
        cancel_at_period_end: false,
        metadata: {
          spider_user_id: "user_test",
        },
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const rawBody = JSON.stringify({
      id: "evt_invoice_paid",
      type: "invoice.paid",
      data: {
        object: {
          customer: "cus_test",
          subscription: "sub_test",
          paid: true,
          status: "paid",
        },
      },
    });

    try {
      const response = await fetchWorker(
        request("/stripe/webhook", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
          },
          body: rawBody,
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 200);
      assert.equal(body.received, true);
      assert.equal(stripeFetchURL, "https://api.stripe.com/v1/subscriptions/sub_test");
      assert.equal(stripeFetchMethod, "GET");
      assert.equal(stripeFetchAuthorization, `Bearer ${env.STRIPE_SECRET_KEY}`);
      assert.match(statements, /subscription_status = \?/);
      assert.match(statements, /entitlement_status = \?/);
      assert.match(statements, /"active"/);
      assert.match(statements, /1800000000/);
      assert.match(statements, /"user_test"/);
      assert.match(statements, /SET processed_at = unixepoch\(\)/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Stripe failed invoice webhooks reconcile non-active subscription state", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      return new Response(JSON.stringify({
        id: "sub_test",
        customer: "cus_test",
        status: "past_due",
        current_period_end: 1_800_000_000,
        cancel_at_period_end: false,
        metadata: {
          spider_user_id: "user_test",
        },
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const rawBody = JSON.stringify({
      id: "evt_invoice_failed",
      type: "invoice.payment_failed",
      data: {
        object: {
          customer: "cus_test",
          subscription: "sub_test",
          paid: false,
          status: "open",
        },
      },
    });

    try {
      const response = await fetchWorker(
        request("/stripe/webhook", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
          },
          body: rawBody,
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 200);
      assert.equal(body.received, true);
      assert.match(statements, /subscription_status = \?/);
      assert.match(statements, /entitlement_status = \?/);
      assert.match(statements, /"past_due"/);
      assert.match(statements, /"canceled"/);
      assert.doesNotMatch(statements, /entitlement_status = 'active'/);
      assert.match(statements, /SET processed_at = unixepoch\(\)/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("Stripe invoice webhooks without subscription do not call Stripe or update entitlement", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let stripeFetchCalls = 0;
    globalThis.fetch = async () => {
      stripeFetchCalls += 1;
      return new Response("unexpected", { status: 500 });
    };
    const rawBody = JSON.stringify({
      id: "evt_invoice_without_subscription",
      type: "invoice.paid",
      data: {
        object: {
          customer: "cus_test",
          paid: true,
          status: "paid",
        },
      },
    });

    try {
      const response = await fetchWorker(
        request("/stripe/webhook", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "stripe-signature": stripeSignatureHeader(rawBody, env.STRIPE_WEBHOOK_SECRET),
          },
          body: rawBody,
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 200);
      assert.equal(body.received, true);
      assert.equal(stripeFetchCalls, 0);
      assert.doesNotMatch(statements, /subscription_status = \?/);
      assert.doesNotMatch(statements, /entitlement_status = \?/);
      assert.match(statements, /SET processed_at = unixepoch\(\)/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}
