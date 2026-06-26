import assert from "node:assert/strict";

export function registerBillingCheckoutPortalAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_SESSION_TOKEN,
  paidUserRow,
  unpaidUserRow,
}) {
  test("billing checkout sessions carry subscription metadata for webhook correlation", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: unpaidUserRow({
          stripe_customer_id: "cus_test",
        }),
      }),
    });
    const previousFetch = globalThis.fetch;
    let stripeRequestBody = "";
    globalThis.fetch = async (_url, init) => {
      stripeRequestBody = String(init.body);
      return new Response(JSON.stringify({ url: "https://checkout.stripe.com/c/pay/cs_test" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/billing/checkout", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.equal(body.url, "https://checkout.stripe.com/c/pay/cs_test");
      assert.match(stripeRequestBody, /mode=subscription/);
      assert.match(stripeRequestBody, /client_reference_id=user_test/);
      assert.match(stripeRequestBody, /metadata%5Bspider_user_id%5D=user_test/);
      assert.match(stripeRequestBody, /subscription_data%5Bmetadata%5D%5Bspider_user_id%5D=user_test/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing checkout fails missing Stripe API key before audit or fetch", async () => {
    const env = baseEnv({
      STRIPE_SECRET_KEY: "",
      DB: new MockD1Database({
        userRow: unpaidUserRow(),
      }),
    });
    const previousFetch = globalThis.fetch;
    let stripeFetchCalls = 0;
    globalThis.fetch = async () => {
      stripeFetchCalls += 1;
      return new Response("unexpected", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/billing/checkout", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 500);
      assert.equal(body.error, "Stripe API key is not configured.");
      assert.equal(stripeFetchCalls, 0);
      assert.doesNotMatch(statements, /billing_checkout_started/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing checkout rejects unsafe Stripe checkout URLs", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: unpaidUserRow(),
      }),
    });
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () =>
      new Response(JSON.stringify({ url: "https://checkout.stripe.evil.test/session" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });

    try {
      const response = await fetchWorker(
        request("/billing/checkout", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "Stripe returned an unsafe Checkout URL.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing checkout blocks users with active entitlement before calling Stripe", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let stripeFetchCalls = 0;
    globalThis.fetch = async () => {
      stripeFetchCalls += 1;
      return new Response("unexpected", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/billing/checkout", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 409);
      assert.equal(body.error, "Subscription is already active.");
      assert.equal(stripeFetchCalls, 0);
      assert.doesNotMatch(statements, /billing_checkout_started/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing checkout blocks canceled subscriptions while paid period is still active", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          entitlement_status: "canceled",
          subscription_status: "canceled",
          subscription_current_period_end: Math.floor(Date.now() / 1000) + 86_400,
        }),
      }),
    });
    const previousFetch = globalThis.fetch;
    let stripeFetchCalls = 0;
    globalThis.fetch = async () => {
      stripeFetchCalls += 1;
      return new Response("unexpected", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/billing/checkout", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 409);
      assert.equal(body.error, "Subscription is already active.");
      assert.equal(stripeFetchCalls, 0);
      assert.doesNotMatch(statements, /billing_checkout_started/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing portal returns only Stripe-hosted portal URLs", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          stripe_customer_id: "cus_test",
        }),
      }),
    });
    const previousFetch = globalThis.fetch;
    let stripeRequestBody = "";
    globalThis.fetch = async (_url, init) => {
      stripeRequestBody = String(init.body);
      return new Response(JSON.stringify({ url: "https://billing.stripe.com/p/session/test_portal" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/billing/portal", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 200);
      assert.equal(body.url, "https://billing.stripe.com/p/session/test_portal");
      assert.match(stripeRequestBody, /customer=cus_test/);
      assert.match(stripeRequestBody, /return_url=https%3A%2F%2Fspider.test%2Faccount/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing portal fails missing Stripe API key before audit or fetch", async () => {
    const env = baseEnv({
      STRIPE_SECRET_KEY: "",
      DB: new MockD1Database({
        userRow: paidUserRow({
          stripe_customer_id: "cus_test",
        }),
      }),
    });
    const previousFetch = globalThis.fetch;
    let stripeFetchCalls = 0;
    globalThis.fetch = async () => {
      stripeFetchCalls += 1;
      return new Response("unexpected", { status: 500 });
    };

    try {
      const response = await fetchWorker(
        request("/billing/portal", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();
      const statements = JSON.stringify(env.DB.executedStatements);

      assert.equal(response.status, 500);
      assert.equal(body.error, "Stripe API key is not configured.");
      assert.equal(stripeFetchCalls, 0);
      assert.doesNotMatch(statements, /billing_portal_started/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("billing portal rejects unsafe Stripe portal URLs", async () => {
    const env = baseEnv({
      DB: new MockD1Database({
        userRow: paidUserRow({
          stripe_customer_id: "cus_test",
        }),
      }),
    });
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () =>
      new Response(JSON.stringify({ url: "https://user:pass@billing.stripe.test/session" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });

    try {
      const response = await fetchWorker(
        request("/billing/portal", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "x-spider-device-id": "device_test",
          },
        }),
        env
      );
      const body = await response.json();

      assert.equal(response.status, 502);
      assert.equal(body.error, "Stripe returned an unsafe billing portal URL.");
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}
