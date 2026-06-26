import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  paidUserRow,
  validVisionGuideBody,
} from "./guideFixtures.mjs";

export const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const bundleDir = mkdtempSync(path.join(tmpdir(), "spider-worker-smoke-"));

try {
  execFileSync("npx", ["wrangler", "deploy", "--dry-run", "--outdir", bundleDir], {
    cwd: workerRoot,
    stdio: "pipe",
  });
} catch (error) {
  process.stderr.write(error.stdout?.toString() || "");
  process.stderr.write(error.stderr?.toString() || "");
  throw error;
}

const bundledWorkerPath = path.join(bundleDir, "index.js");
const importableWorkerPath = path.join(bundleDir, "index.mjs");
writeFileSync(importableWorkerPath, readFileSync(bundledWorkerPath, "utf8"));

const workerModule = await import(pathToFileURL(importableWorkerPath).href);
export const worker = workerModule.default;

export const TEST_MAGIC_LINK_TOKEN = "00000000-0000-4000-8000-00000000000100000000-0000-4000-8000-000000000002";
export const TEST_SESSION_TOKEN = "10000000-0000-4000-8000-00000000000110000000-0000-4000-8000-000000000002";

const tests = [];

export function test(name, fn) {
  tests.push({ name, fn });
}

export function baseEnv(overrides = {}) {
  const { DB = new MockD1Database(), ...envOverrides } = overrides;
  return {
    DB,
    OPENAI_API_KEY: "openai-test-key",
    OPENAI_VISION_MODEL: "gpt-5.5",
    OPENAI_REALTIME_MODEL: "gpt-realtime-2",
    EMAIL_HASH_SECRET: "email-hash-secret-for-tests",
    STRIPE_SECRET_KEY: "stripe-secret-for-tests",
    STRIPE_PRICE_ID: "stripe-price-for-tests",
    STRIPE_SUCCESS_URL: "https://spider.test/account",
    STRIPE_CANCEL_URL: "https://spider.test/account",
    STRIPE_WEBHOOK_SECRET: "stripe-webhook-secret-for-tests",
    ALLOWED_WEB_ORIGINS: "",
    ...envOverrides,
  };
}

export function request(pathname, init = {}) {
  return new Request(`https://api.spider.test${pathname}`, init);
}

export async function fetchWorker(req, env = baseEnv()) {
  const ctx = new TestExecutionContext();
  const response = await worker.fetch(req, env, ctx);
  await ctx.drain();
  return response;
}

export async function fetchVisionGuideWithMockedGuideOutput(
  guideOutput,
  env = baseEnv(),
  body = validVisionGuideBody()
) {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({
    output_text: JSON.stringify(guideOutput),
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

  try {
    return await fetchWorker(
      request("/vision/guide", {
        method: "POST",
        headers: {
          authorization: `Bearer ${TEST_SESSION_TOKEN}`,
          "content-type": "application/json",
          "x-spider-device-id": "device_test",
        },
        body: JSON.stringify(body),
      }),
      env
    );
  } finally {
    globalThis.fetch = previousFetch;
  }
}

export class TestExecutionContext {
  constructor() {
    this.promises = [];
  }

  waitUntil(promise) {
    this.promises.push(Promise.resolve(promise));
  }

  async drain() {
    await Promise.all(this.promises);
  }
}

export function stripeSignatureHeader(rawBody, secret, timestamp = Math.floor(Date.now() / 1000)) {
  const signature = createHmac("sha256", secret)
    .update(`${timestamp}.${rawBody}`)
    .digest("hex");
  return `t=${timestamp},v1=${signature}`;
}

export function sha256HexForTest(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function capturedHeader(headers, name) {
  if (headers instanceof Headers) {
    return headers.get(name);
  }
  return headers?.[name] || headers?.[name.toLowerCase()] || null;
}

export class MockD1Database {
  constructor(options = {}) {
    this.executedStatements = [];
    this.batchedStatements = [];
    this.userRow = options.userRow || paidUserRow();
    this.usageCounts = options.usageCounts || {};
    this.rateCounts = options.rateCounts || {};
    this.sessionDeviceHash = Object.hasOwn(options, "sessionDeviceHash")
      ? options.sessionDeviceHash
      : sha256HexForTest("device_test");
  }

  prepare(sql) {
    return new MockD1Statement(this, sql);
  }

  async batch(statements) {
    this.batchedStatements.push(...statements.map((statement) => statement.sql));
    return statements.map(() => ({ success: true }));
  }
}

class MockD1Statement {
  constructor(database, sql) {
    this.database = database;
    this.sql = sql;
    this.params = [];
  }

  bind(...params) {
    this.params = params;
    return this;
  }

  async first() {
    this.database.executedStatements.push({ operation: "first", sql: this.sql, params: this.params });

    if (this.sql.includes("JOIN users ON users.id = sessions.user_id")) {
      const requestDeviceHash = this.params[1] || null;
      if (!this.database.sessionDeviceHash || requestDeviceHash !== this.database.sessionDeviceHash) {
        return null;
      }
      return this.database.userRow;
    }

    if (this.sql.includes("INSERT INTO usage_counters")) {
      const quotaKind = this.params[1];
      const dailyLimit = this.params[3];
      const currentCount = this.database.usageCounts[quotaKind] || 0;
      if (currentCount >= dailyLimit) {
        return null;
      }
      this.database.usageCounts[quotaKind] = currentCount + 1;
      return { count: this.database.usageCounts[quotaKind] };
    }

    if (this.sql.includes("INSERT INTO rate_counters")) {
      const quotaKind = this.params[1];
      const dailyLimit = this.params[3];
      const currentCount = this.database.rateCounts[quotaKind] || 0;
      if (currentCount >= dailyLimit) {
        return null;
      }
      this.database.rateCounts[quotaKind] = currentCount + 1;
      return { count: this.database.rateCounts[quotaKind] };
    }

    if (this.sql.includes("SELECT id FROM users")) {
      return { id: "user_test" };
    }

    if (this.sql.includes("FROM magic_links")) {
      return {
        user_id: "user_test",
        expires_at: Math.floor(Date.now() / 1000) + 900,
        consumed_at: null,
      };
    }

    return null;
  }

  async run() {
    this.database.executedStatements.push({ operation: "run", sql: this.sql, params: this.params });
    return { meta: { changes: 1 } };
  }
}

export async function runSmokeTests() {
  for (const { name, fn } of tests) {
    try {
      await fn();
      console.log(`ok - ${name}`);
    } catch (error) {
      console.error(`not ok - ${name}`);
      throw error;
    }
  }
}
