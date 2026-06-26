ALTER TABLE stripe_events ADD COLUMN processing_started_at INTEGER;
ALTER TABLE stripe_events ADD COLUMN processed_at INTEGER;
ALTER TABLE stripe_events ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;

UPDATE stripe_events
SET processed_at = created_at
WHERE processed_at IS NULL;
