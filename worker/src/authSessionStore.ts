export type EntitlementStatus = "active" | "trial" | "canceled" | "blocked" | "none";

export interface AuthenticatedUser {
  id: string;
  emailHash: string;
  entitlementStatus: EntitlementStatus;
  stripeCustomerId: string | null;
  stripeSubscriptionId: string | null;
  subscriptionStatus: string | null;
  subscriptionCurrentPeriodEnd: number | null;
  cancelAtPeriodEnd: boolean;
}

export interface MagicLinkRecord {
  userId: string;
  expiresAt: number;
  consumedAt: number | null;
}

interface UserIDRow {
  id: string;
}

interface AuthenticatedUserRow {
  id: string;
  email_hash: string;
  entitlement_status: EntitlementStatus;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  subscription_status: string | null;
  subscription_current_period_end: number | null;
  cancel_at_period_end: number;
}

interface MagicLinkRow {
  user_id: string;
  expires_at: number;
  consumed_at: number | null;
}

export async function upsertUserByEmailHash(
  env: Env,
  input: { id: string; emailHash: string }
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO users (id, email_hash, entitlement_status, created_at, updated_at)
     VALUES (?, ?, 'none', unixepoch(), unixepoch())
     ON CONFLICT(email_hash) DO UPDATE SET updated_at = unixepoch()`
  ).bind(input.id, input.emailHash).run();
}

export async function findUserByEmailHash(env: Env, emailHash: string): Promise<UserIDRow | null> {
  return await env.DB.prepare(
    `SELECT id FROM users WHERE email_hash = ?`
  ).bind(emailHash).first<UserIDRow>();
}

export async function createMagicLink(
  env: Env,
  input: { tokenHash: string; userId: string; expiresAt: number }
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO magic_links (token_hash, user_id, expires_at, consumed_at, created_at)
     VALUES (?, ?, ?, NULL, unixepoch())`
  ).bind(input.tokenHash, input.userId, input.expiresAt).run();
}

export async function findUsableMagicLinkByHash(
  env: Env,
  tokenHash: string,
  nowSeconds: number
): Promise<MagicLinkRecord | null> {
  const row = await env.DB.prepare(
    `SELECT user_id, expires_at, consumed_at
     FROM magic_links
     WHERE token_hash = ?`
  ).bind(tokenHash).first<MagicLinkRow>();

  if (!row || row.consumed_at !== null || row.expires_at < nowSeconds) {
    return null;
  }

  return {
    userId: row.user_id,
    expiresAt: row.expires_at,
    consumedAt: row.consumed_at,
  };
}

export async function consumeMagicLinkByHash(env: Env, tokenHash: string): Promise<void> {
  await env.DB.prepare(
    `UPDATE magic_links
     SET consumed_at = unixepoch()
     WHERE token_hash = ?
       AND consumed_at IS NULL`
  ).bind(tokenHash).run();
}

export async function consumeActiveMagicLinkByHash(env: Env, tokenHash: string): Promise<boolean> {
  const result = await env.DB.prepare(
    `UPDATE magic_links
     SET consumed_at = unixepoch()
     WHERE token_hash = ?
       AND consumed_at IS NULL
       AND expires_at >= unixepoch()`
  ).bind(tokenHash).run();

  return result.meta.changes === 1;
}

export async function revokePreviousActiveMagicLinks(
  env: Env,
  userId: string,
  currentTokenHash: string
): Promise<void> {
  await env.DB.prepare(
    `UPDATE magic_links
     SET consumed_at = unixepoch()
     WHERE user_id = ?
       AND token_hash != ?
       AND consumed_at IS NULL
       AND expires_at >= unixepoch()`
  ).bind(userId, currentTokenHash).run();
}

export async function createDeviceBoundSession(
  env: Env,
  input: { tokenHash: string; userId: string; expiresAt: number; deviceHash: string }
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO sessions (token_hash, user_id, expires_at, revoked_at, created_at, device_hash)
     VALUES (?, ?, ?, NULL, unixepoch(), ?)`
  ).bind(input.tokenHash, input.userId, input.expiresAt, input.deviceHash).run();
}

export async function revokeSessionByHash(env: Env, tokenHash: string): Promise<void> {
  await env.DB.prepare(
    `UPDATE sessions
     SET revoked_at = unixepoch()
     WHERE token_hash = ?
       AND revoked_at IS NULL`
  ).bind(tokenHash).run();
}

export async function findAuthenticatedUserBySession(
  env: Env,
  input: { tokenHash: string; deviceHash: string }
): Promise<AuthenticatedUser | null> {
  const row = await env.DB.prepare(
    `SELECT users.id,
            users.email_hash,
            users.entitlement_status,
            users.stripe_customer_id,
            users.stripe_subscription_id,
            users.subscription_status,
            users.subscription_current_period_end,
            users.cancel_at_period_end
     FROM sessions
     JOIN users ON users.id = sessions.user_id
     WHERE sessions.token_hash = ?
       AND sessions.revoked_at IS NULL
       AND sessions.expires_at > unixepoch()
       AND sessions.device_hash = ?`
  ).bind(input.tokenHash, input.deviceHash).first<AuthenticatedUserRow>();

  if (!row) {
    return null;
  }

  return {
    id: row.id,
    emailHash: row.email_hash,
    entitlementStatus: row.entitlement_status,
    stripeCustomerId: row.stripe_customer_id,
    stripeSubscriptionId: row.stripe_subscription_id,
    subscriptionStatus: row.subscription_status,
    subscriptionCurrentPeriodEnd: row.subscription_current_period_end,
    cancelAtPeriodEnd: row.cancel_at_period_end === 1,
  };
}
