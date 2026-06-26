ALTER TABLE sessions ADD COLUMN device_hash TEXT;

CREATE INDEX IF NOT EXISTS idx_sessions_device_hash
  ON sessions(device_hash)
  WHERE device_hash IS NOT NULL;

UPDATE sessions
SET revoked_at = unixepoch()
WHERE device_hash IS NULL
  AND revoked_at IS NULL;
