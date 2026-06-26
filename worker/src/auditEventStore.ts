export type AuditEventName =
  | "auth_magic_link_started"
  | "auth_session_created"
  | "auth_session_revoked"
  | "vision_guide_requested"
  | "realtime_client_secret_requested"
  | "billing_checkout_started"
  | "billing_checkout_completed"
  | "billing_portal_started";

export async function recordAuditEvent(env: Env, userId: string, eventName: AuditEventName): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO audit_events (id, user_id, event_name, created_at)
     VALUES (?, ?, ?, unixepoch())`
  ).bind(crypto.randomUUID(), userId, eventName).run();
}
