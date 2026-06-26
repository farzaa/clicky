const DAY_IN_SECONDS = 86_400;
const MAGIC_LINK_RETENTION_SECONDS = 7 * DAY_IN_SECONDS;
const SESSION_RETENTION_SECONDS = 90 * DAY_IN_SECONDS;
const AUDIT_RETENTION_SECONDS = 90 * DAY_IN_SECONDS;
const STRIPE_EVENT_RETENTION_SECONDS = 180 * DAY_IN_SECONDS;

export async function pruneOperationalRows(env: Env): Promise<void> {
  const usageCounterCutoffDay = dayStringDaysAgo(60);
  const rateCounterCutoffDay = dayStringDaysAgo(30);

  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM magic_links
       WHERE expires_at < unixepoch() - ?`
    ).bind(MAGIC_LINK_RETENTION_SECONDS),
    env.DB.prepare(
      `DELETE FROM sessions
       WHERE expires_at < unixepoch() - ?
          OR (
            revoked_at IS NOT NULL
            AND revoked_at < unixepoch() - ?
          )`
    ).bind(SESSION_RETENTION_SECONDS, SESSION_RETENTION_SECONDS),
    env.DB.prepare(
      `DELETE FROM usage_counters
       WHERE day < ?`
    ).bind(usageCounterCutoffDay),
    env.DB.prepare(
      `DELETE FROM rate_counters
       WHERE day < ?`
    ).bind(rateCounterCutoffDay),
    env.DB.prepare(
      `DELETE FROM audit_events
       WHERE created_at < unixepoch() - ?`
    ).bind(AUDIT_RETENTION_SECONDS),
    env.DB.prepare(
      `DELETE FROM stripe_events
       WHERE processed_at IS NOT NULL
         AND processed_at < unixepoch() - ?`
    ).bind(STRIPE_EVENT_RETENTION_SECONDS),
  ]);
}

function dayStringDaysAgo(daysAgo: number): string {
  const date = new Date(Date.now() - daysAgo * DAY_IN_SECONDS * 1000);
  return date.toISOString().slice(0, 10);
}
