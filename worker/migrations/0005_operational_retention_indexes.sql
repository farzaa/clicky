CREATE INDEX IF NOT EXISTS idx_sessions_revoked_at
  ON sessions(revoked_at)
  WHERE revoked_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_usage_counters_day
  ON usage_counters(day);

CREATE INDEX IF NOT EXISTS idx_rate_counters_day
  ON rate_counters(day);

CREATE INDEX IF NOT EXISTS idx_audit_events_created_at
  ON audit_events(created_at);

CREATE INDEX IF NOT EXISTS idx_stripe_events_processed_at
  ON stripe_events(processed_at)
  WHERE processed_at IS NOT NULL;
