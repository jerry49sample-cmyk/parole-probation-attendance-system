-- Adds server-controlled, atomic cooldowns for tracking alerts.
-- Review and run only after setup_access_policies.sql and
-- setup_esp32_trackers.sql; this script does not modify existing alert records.

DO $$
DECLARE
  missing_columns text;
  incompatible_columns text;
BEGIN
  IF to_regclass('public.tracking_alert_cooldowns') IS NOT NULL THEN
    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
    FROM (VALUES
      ('id'),
      ('alert_type'),
      ('tracker_id'),
      ('parolee_id'),
      ('last_sent_at')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'public'
        AND actual.table_name = 'tracking_alert_cooldowns'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.tracking_alert_cooldowns is incompatible; missing columns: %. Review its schema before running this script.',
        missing_columns;
    END IF;

    SELECT string_agg(
      format('%s (expected %s, found %s)', required.column_name, required.data_type, actual.data_type),
      ', '
    )
    INTO incompatible_columns
    FROM (VALUES
      ('id', 'text'),
      ('alert_type', 'text'),
      ('tracker_id', 'text'),
      ('parolee_id', 'text'),
      ('last_sent_at', 'timestamp with time zone')
    ) AS required(column_name, data_type)
    JOIN information_schema.columns AS actual
      ON actual.table_schema = 'public'
     AND actual.table_name = 'tracking_alert_cooldowns'
     AND actual.column_name = required.column_name
    WHERE actual.data_type <> required.data_type;

    IF incompatible_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.tracking_alert_cooldowns has incompatible column types: %. Review its schema before running this script.',
        incompatible_columns;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = to_regclass('public.tracking_alert_cooldowns')
        AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
    ) THEN
      RAISE EXCEPTION
        'Existing public.tracking_alert_cooldowns must have PRIMARY KEY (id). Review its schema before running this script.';
    END IF;
  END IF;

  IF to_regprocedure('public.ppa_current_role()') IS NULL
    OR to_regprocedure('public.ppa_is_assigned_officer(text)') IS NULL
  THEN
    RAISE EXCEPTION
      'Run setup_access_policies.sql before setting up tracking alert cooldowns.';
  END IF;
  IF to_regclass('public.gps_trackers') IS NULL THEN
    RAISE EXCEPTION
      'Run setup_esp32_trackers.sql before setting up tracking alert cooldowns.';
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.tracking_alert_cooldowns (
  id text PRIMARY KEY,
  alert_type text NOT NULL,
  tracker_id text NOT NULL,
  parolee_id text NOT NULL,
  last_sent_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tracking_alert_cooldowns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tracking_alert_cooldowns FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ppa_should_send_tracking_alert(
  p_alert_type text,
  p_tracker_id text,
  p_cooldown_seconds integer DEFAULT 1800
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text := public.ppa_current_role();
  v_parolee_id text;
  v_cooldown_id text;
  v_updated_id text;
BEGIN
  IF v_role NOT IN ('officer', 'admin') THEN
    RAISE EXCEPTION 'Only active officers or administrators can request tracking alerts';
  END IF;
  IF p_alert_type IS NULL
    OR p_alert_type !~ '^[a-z][a-z0-9_]{0,63}$'
    OR p_tracker_id IS NULL
    OR length(trim(p_tracker_id)) = 0
    OR length(p_tracker_id) > 128
  THEN
    RAISE EXCEPTION 'Invalid tracking alert or tracker';
  END IF;
  IF p_cooldown_seconds IS NULL OR p_cooldown_seconds < 0 OR p_cooldown_seconds > 604800 THEN
    RAISE EXCEPTION 'Tracking alert cooldown must be between zero and seven days';
  END IF;

  SELECT tracker.parolee_id::text
  INTO v_parolee_id
  FROM public.gps_trackers AS tracker
  WHERE tracker.id::text = p_tracker_id;

  IF NOT FOUND OR v_parolee_id IS NULL THEN
    RETURN false;
  END IF;
  IF v_role = 'officer' AND NOT public.ppa_is_assigned_officer(v_parolee_id) THEN
    RAISE EXCEPTION 'The tracker is assigned outside your caseload';
  END IF;

  v_cooldown_id := jsonb_build_array(p_alert_type, p_tracker_id, v_parolee_id)::text;

  INSERT INTO public.tracking_alert_cooldowns AS cooldown (
    id,
    alert_type,
    tracker_id,
    parolee_id,
    last_sent_at
  )
  VALUES (
    v_cooldown_id,
    p_alert_type,
    p_tracker_id,
    v_parolee_id,
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET last_sent_at = EXCLUDED.last_sent_at
  WHERE cooldown.last_sent_at
    <= EXCLUDED.last_sent_at - make_interval(secs => p_cooldown_seconds)
  RETURNING id INTO v_updated_id;

  RETURN v_updated_id IS NOT NULL;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_should_send_tracking_alert(text, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_should_send_tracking_alert(text, text, integer)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
