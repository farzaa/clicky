interface CounterRow {
  count: number;
}

export async function consumeDailyUserQuota(
  env: Env,
  input: { userId: string; quotaKind: string; day: string; dailyLimit: number }
): Promise<boolean> {
  const consumedCounter = await env.DB.prepare(
    `INSERT INTO usage_counters (user_id, quota_kind, day, count, updated_at)
     VALUES (?, ?, ?, 1, unixepoch())
     ON CONFLICT(user_id, quota_kind, day)
     DO UPDATE SET count = count + 1, updated_at = unixepoch()
       WHERE count < ?
     RETURNING count`
  ).bind(input.userId, input.quotaKind, input.day, input.dailyLimit).first<CounterRow>();

  return consumedCounter !== null;
}

export async function consumeDailyActorRateLimit(
  env: Env,
  input: { actorHash: string; quotaKind: string; day: string; dailyLimit: number }
): Promise<boolean> {
  const consumedCounter = await env.DB.prepare(
    `INSERT INTO rate_counters (actor_hash, quota_kind, day, count, updated_at)
     VALUES (?, ?, ?, 1, unixepoch())
     ON CONFLICT(actor_hash, quota_kind, day)
     DO UPDATE SET count = count + 1, updated_at = unixepoch()
       WHERE count < ?
     RETURNING count`
  ).bind(input.actorHash, input.quotaKind, input.day, input.dailyLimit).first<CounterRow>();

  return consumedCounter !== null;
}
