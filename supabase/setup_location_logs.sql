-- Run this only if verify_schema.sql reports these columns as missing.
-- It preserves existing rows. New GPS records receive created_at automatically.

ALTER TABLE public.location_logs
  ADD COLUMN IF NOT EXISTS tracker_id text,
  ADD COLUMN IF NOT EXISTS parolee_id text,
  ADD COLUMN IF NOT EXISTS accuracy double precision,
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

-- Set the default separately so existing records are not assigned a fabricated
-- timestamp at migration time.
ALTER TABLE public.location_logs
  ALTER COLUMN created_at SET DEFAULT now();

-- Preserve existing event times where the legacy column is a SQL timestamp.
DO $$
DECLARE
  legacy_type text;
BEGIN
  SELECT data_type
  INTO legacy_type
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'location_logs'
    AND column_name = 'recorded_at';

  IF legacy_type IN (
    'timestamp with time zone',
    'timestamp without time zone',
    'date'
  ) THEN
    EXECUTE '
      UPDATE public.location_logs
      SET created_at = recorded_at::timestamptz
      WHERE created_at IS NULL
        AND recorded_at IS NOT NULL
    ';
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS location_logs_created_at_idx
  ON public.location_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS location_logs_parolee_created_at_idx
  ON public.location_logs (parolee_id, created_at DESC);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'location_logs'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.location_logs';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
