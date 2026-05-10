-- Dot inference gateway — D1 schema
--
-- Apply this once to a fresh D1 database:
--   npx wrangler d1 execute dot-proxy --file=schema.sql
--
-- All timestamps are unix seconds (INTEGER) so the Worker can use Math.floor(Date.now()/1000)
-- without a date-time conversion layer.

-- ----------------------------------------------------------------------------
-- users — created on first Google OAuth sign-in
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  google_subject TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  display_name TEXT,
  picture_url TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  status TEXT NOT NULL DEFAULT 'active',           -- 'active' | 'blocked'
  daily_chat_limit INTEGER NOT NULL DEFAULT 200,
  daily_tts_chars_limit INTEGER NOT NULL DEFAULT 50000,
  daily_transcribe_session_limit INTEGER NOT NULL DEFAULT 100
);

CREATE INDEX IF NOT EXISTS idx_users_google_subject ON users(google_subject);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- ----------------------------------------------------------------------------
-- oauth_states — short-lived state for the /auth/start → /auth/callback round trip.
-- Created on /auth/start, deleted on /auth/callback. Cleaned up after 10 minutes.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oauth_states (
  state TEXT PRIMARY KEY,
  device_id TEXT,
  return_to_url TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_oauth_states_created_at ON oauth_states(created_at);

-- ----------------------------------------------------------------------------
-- auth_codes — short-lived single-use codes minted at /auth/callback for the
-- macOS app to exchange via /auth/exchange. Cleaned up after 5 minutes.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auth_codes (
  code TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  device_id TEXT,
  created_at INTEGER NOT NULL,
  consumed_at INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_auth_codes_created_at ON auth_codes(created_at);

-- ----------------------------------------------------------------------------
-- devices — long-lived install tokens. One row per (user, device_id).
-- We store SHA-256(install_token), never the token itself.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  device_id TEXT NOT NULL,
  install_token_hash TEXT NOT NULL UNIQUE,
  device_label TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_devices_install_token_hash ON devices(install_token_hash);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_devices_user_device ON devices(user_id, device_id);

-- ----------------------------------------------------------------------------
-- usage_events — one row per upstream API call. Used for quota enforcement
-- (sum amount within last 86400 seconds) and admin reporting.
--
-- amount semantics:
--   chat              → 1 (one Claude call)
--   tts               → number of characters of text spoken
--   transcribe-token  → 1 (one AssemblyAI session token issued)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usage_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  device_id TEXT,
  endpoint TEXT NOT NULL,
  status_code INTEGER NOT NULL,
  amount INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_usage_events_user_endpoint_created
  ON usage_events(user_id, endpoint, created_at);

CREATE INDEX IF NOT EXISTS idx_usage_events_created
  ON usage_events(created_at);
