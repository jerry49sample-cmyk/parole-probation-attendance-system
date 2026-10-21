-- Creates the private-to-the-app tracker audit log used by tracking services.
-- Additive and safe to re-run; review before applying to a live project.
--
-- Run after setup_access_policies.sql and before setup_web_data_flows.sql.

DO $$
DECLARE
  missing_columns text;
  incompatible_columns text;
BEGIN
  IF to_regclass('public.tracking_audit_logs') IS NOT NULL THEN
    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
    FROM (VALUES
      ('id'),
      ('action'),
      ('resource_type'),
      ('resource_id'),
      ('parolee_id'),
      ('actor_id'),
      ('actor_role'),
      ('metadata'),
      ('created_at')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'public'
        AND actual.table_name = 'tracking_audit_logs'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.tracking_audit_logs is incompatible; missing columns: %. Review its schema before running this script.',
        missing_columns;
    END IF;

    SELECT string_agg(
      format(
        '%s (expected %s, found %s)',
        required.column_name,
        required.data_type,
        actual.data_type
      ),
      ', '
    )
    INTO incompatible_columns
    FROM (VALUES
      ('id', 'uuid'),
      ('action', 'text'),
      ('resource_type', 'text'),
      ('resource_id', 'text'),
      ('parolee_id', 'text'),
      ('actor_id', 'text'),
      ('actor_role', 'text'),
      ('metadata', 'jsonb'),
      ('created_at', 'timestamp with time zone')
    ) AS required(column_name, data_type)
    JOIN information_schema.columns AS actual
      ON actual.table_schema = 'public'
     AND actual.table_name = 'tracking_audit_logs'
     AND actual.column_name = required.column_name
    WHERE actual.data_type <> required.data_type;

    IF incompatible_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.tracking_audit_logs has incompatible column types: %. Review its schema before running this script.',
        incompatible_columns;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = to_regclass('public.tracking_audit_logs')
        AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
    ) THEN
      RAISE EXCEPTION
        'Existing public.tracking_audit_logs must have PRIMARY KEY (id). Review its schema before running this script.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'tracking_audit_logs'
        AND column_name IN ('id', 'created_at')
        AND column_default IS NULL
    ) THEN
      RAISE EXCEPTION
        'Existing public.tracking_audit_logs must generate id and created_at values by default. Review its schema before running this script.';
    END IF;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.tracking_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,
  resource_type text NOT NULL,
  resource_id text NOT NULL,
  parolee_id text,
  actor_id text,
  actor_role text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tracking_audit_logs_created_at_idx
  ON public.tracking_audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS tracking_audit_logs_resource_idx
  ON public.tracking_audit_logs (resource_type, resource_id, created_at DESC);

ALTER TABLE public.tracking_audit_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tracking_audit_logs FROM PUBLIC, anon, authenticated;
GRANT INSERT ON TABLE public.tracking_audit_logs TO authenticated;

DROP POLICY IF EXISTS ppa_tracking_audit_insert_self
  ON public.tracking_audit_logs;
CREATE POLICY ppa_tracking_audit_insert_self
  ON public.tracking_audit_logs
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (actor_id = auth.uid()::text);

-- Prevent any pre-existing permissive policy from allowing forged actor IDs.
DROP POLICY IF EXISTS ppa_tracking_audit_insert_limit
  ON public.tracking_audit_logs;
CREATE POLICY ppa_tracking_audit_insert_limit
  ON public.tracking_audit_logs
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (actor_id = auth.uid()::text);
