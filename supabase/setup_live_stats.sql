-- Officer dashboard summaries. Run after setup_access_policies.sql.
-- Additive and safe to re-run; this does not remove existing rows.

DO $$
BEGIN
  IF to_regprocedure('public.ppa_current_role()') IS NULL
    OR to_regprocedure('public.ppa_is_admin()') IS NULL
  THEN
    RAISE EXCEPTION
      'Run setup_access_policies.sql before setup_live_stats.sql';
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.live_stats (
  officer_id text PRIMARY KEY,
  total_cases integer NOT NULL DEFAULT 0 CHECK (total_cases >= 0),
  checked_in integer NOT NULL DEFAULT 0 CHECK (checked_in >= 0),
  pending integer NOT NULL DEFAULT 0 CHECK (pending >= 0),
  missed integer NOT NULL DEFAULT 0 CHECK (missed >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  checked_in_list jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(checked_in_list) = 'array'),
  pending_list jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(pending_list) = 'array'),
  missed_list jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(missed_list) = 'array')
);

ALTER TABLE public.live_stats ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.live_stats FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.live_stats TO authenticated;

DROP POLICY IF EXISTS ppa_live_stats_read ON public.live_stats;
DROP POLICY IF EXISTS ppa_live_stats_read_limit ON public.live_stats;
CREATE POLICY ppa_live_stats_read ON public.live_stats
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    public.ppa_is_admin()
    OR (
      public.ppa_current_role() = 'officer'
      AND officer_id = auth.uid()::text
    )
  );
CREATE POLICY ppa_live_stats_read_limit ON public.live_stats
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (
    public.ppa_is_admin()
    OR (
      public.ppa_current_role() = 'officer'
      AND officer_id = auth.uid()::text
    )
  );

DROP POLICY IF EXISTS ppa_live_stats_insert ON public.live_stats;
DROP POLICY IF EXISTS ppa_live_stats_insert_limit ON public.live_stats;
CREATE POLICY ppa_live_stats_insert ON public.live_stats
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  );
CREATE POLICY ppa_live_stats_insert_limit ON public.live_stats
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  );

DROP POLICY IF EXISTS ppa_live_stats_update ON public.live_stats;
DROP POLICY IF EXISTS ppa_live_stats_update_limit ON public.live_stats;
CREATE POLICY ppa_live_stats_update ON public.live_stats
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  )
  WITH CHECK (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  );
CREATE POLICY ppa_live_stats_update_limit ON public.live_stats
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  )
  WITH CHECK (
    public.ppa_current_role() = 'officer'
    AND officer_id = auth.uid()::text
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication
    WHERE pubname = 'supabase_realtime'
  ) THEN
    RAISE EXCEPTION
      'The supabase_realtime publication is missing; enable Supabase Realtime before applying this script';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'live_stats'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.live_stats';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
