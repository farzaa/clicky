import assert from "node:assert/strict";

export function registerOperationalRetentionAssertions({
  test,
  baseEnv,
  TestExecutionContext,
  worker,
}) {
  test("scheduled cleanup deletes only operational retention tables", async () => {
    const env = baseEnv();
    const ctx = new TestExecutionContext();

    await worker.scheduled({}, env, ctx);
    await ctx.drain();

    const cleanupSQL = env.DB.batchedStatements.join("\n");
    assert.match(cleanupSQL, /DELETE FROM magic_links/);
    assert.match(cleanupSQL, /DELETE FROM sessions/);
    assert.match(cleanupSQL, /DELETE FROM usage_counters/);
    assert.match(cleanupSQL, /DELETE FROM rate_counters/);
    assert.match(cleanupSQL, /DELETE FROM audit_events/);
    assert.match(cleanupSQL, /DELETE FROM stripe_events/);
    assert.doesNotMatch(cleanupSQL, /DELETE FROM users/);
  });
}
