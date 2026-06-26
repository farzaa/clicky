export type StripeEventReservation = "reserved" | "duplicate";

export async function reserveStripeEvent(
  env: Env,
  eventId: string,
  eventType: string
): Promise<StripeEventReservation> {
  const insertResult = await env.DB.prepare(
    `INSERT OR IGNORE INTO stripe_events
       (id, event_type, created_at, processing_started_at, attempt_count)
     VALUES (?, ?, unixepoch(), unixepoch(), 1)`
  ).bind(eventId, eventType).run();

  if (insertResult.meta.changes === 1) {
    return "reserved";
  }

  const existingEvent = await env.DB.prepare(
    `SELECT processed_at, processing_started_at
     FROM stripe_events
     WHERE id = ?`
  ).bind(eventId).first<{
    processed_at: number | null;
    processing_started_at: number | null;
  }>();

  if (!existingEvent || existingEvent.processed_at !== null) {
    return "duplicate";
  }

  const retryResult = await env.DB.prepare(
    `UPDATE stripe_events
     SET processing_started_at = unixepoch(),
         attempt_count = attempt_count + 1
     WHERE id = ?
       AND processed_at IS NULL
       AND (
         processing_started_at IS NULL
         OR processing_started_at < unixepoch() - 300
       )`
  ).bind(eventId).run();

  return retryResult.meta.changes === 1 ? "reserved" : "duplicate";
}

export async function markStripeEventProcessed(env: Env, eventId: string): Promise<void> {
  await env.DB.prepare(
    `UPDATE stripe_events
     SET processed_at = unixepoch(),
         processing_started_at = NULL
     WHERE id = ?`
  ).bind(eventId).run();
}

export async function releaseStripeEventReservation(env: Env, eventId: string): Promise<void> {
  await env.DB.prepare(
    `UPDATE stripe_events
     SET processing_started_at = NULL
     WHERE id = ?
       AND processed_at IS NULL`
  ).bind(eventId).run();
}
