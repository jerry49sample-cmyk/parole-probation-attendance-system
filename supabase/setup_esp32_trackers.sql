-- ESP32 inventory and per-device credential storage.
-- Run after setup_location_logs.sql. Then run setup_access_policies.sql.
-- This script does not create or expose a raw device token.

DO $$
BEGIN
  IF to_regclass('public.location_logs') IS NULL THEN
    RAISE EXCEPTION
      'ESP32 setup stopped: public.location_logs is missing; run setup_location_logs.sql first.';
  END IF;

  IF EXISTS (
    SELECT required.column_name
    FROM (VALUES
      ('tracker_id'),
      ('parolee_id'),
      ('latitude'),
      ('longitude'),
      ('accuracy'),
      ('speed'),
      ('battery_level'),
      ('created_at')
    ) AS required(column_name)
    LEFT JOIN information_schema.columns AS actual
      ON actual.table_schema = 'public'
     AND actual.table_name = 'location_logs'
     AND actual.column_name = required.column_name
    WHERE actual.column_name IS NULL
  ) THEN
    RAISE EXCEPTION
      'ESP32 setup stopped: public.location_logs is missing required location columns; run setup_location_logs.sql first.';
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.gps_trackers (
  id text PRIMARY KEY,
  device_id text NOT NULL UNIQUE,
  device_name text,
  device_type text,
  serial_number text,
  parolee_id text,
  parolee_name text,
  status text NOT NULL DEFAULT 'unassigned'
    CHECK (status IN ('active', 'inactive', 'offline', 'maintenance', 'unassigned')),
  battery_level smallint
    CHECK (battery_level IS NULL OR battery_level BETWEEN 0 AND 100),
  last_seen_at timestamptz,
  assigned_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.gps_tracker_credentials (
  tracker_id text PRIMARY KEY
    REFERENCES public.gps_trackers(id) ON DELETE CASCADE,
  token_hash text NOT NULL
    CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  rotated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gps_trackers_parolee_id_idx
  ON public.gps_trackers (parolee_id);
CREATE INDEX IF NOT EXISTS gps_trackers_status_idx
  ON public.gps_trackers (status);

ALTER TABLE public.gps_trackers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gps_tracker_credentials ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.gps_trackers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.gps_tracker_credentials
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.gps_trackers TO service_role;
GRANT SELECT ON TABLE public.gps_tracker_credentials TO service_role;

-- The Edge Function passes a SHA-256 token digest. Rechecking it in this
-- transaction closes the race between credential rotation and location insert.
CREATE OR REPLACE FUNCTION public.ppa_record_tracker_location(
  p_tracker_id text,
  p_token_hash text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy double precision DEFAULT NULL,
  p_speed double precision DEFAULT NULL,
  p_battery_level integer DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  assigned_parolee_id text;
  tracker_status text;
  saved_token_hash text;
  credential_active boolean;
BEGIN
  IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$'
    OR p_latitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90
    OR p_longitude IS NULL OR p_longitude NOT BETWEEN -180 AND 180
    OR (p_latitude = 0 AND p_longitude = 0)
    OR (p_accuracy IS NOT NULL AND p_accuracy NOT BETWEEN 0 AND 10000)
    OR (p_speed IS NOT NULL AND p_speed NOT BETWEEN 0 AND 1000)
    OR (p_battery_level IS NOT NULL AND p_battery_level NOT BETWEEN 0 AND 100)
  THEN
    RAISE EXCEPTION 'invalid_tracker_location'
      USING ERRCODE = '22023';
  END IF;

  SELECT t.parolee_id, t.status, c.token_hash, c.is_active
    INTO assigned_parolee_id, tracker_status, saved_token_hash, credential_active
  FROM public.gps_trackers AS t
  JOIN public.gps_tracker_credentials AS c ON c.tracker_id = t.id
  WHERE t.id = p_tracker_id
  FOR UPDATE OF t, c;

  IF NOT FOUND
    OR NOT credential_active
    OR saved_token_hash IS DISTINCT FROM p_token_hash
    OR tracker_status <> 'active'
    OR assigned_parolee_id IS NULL
    OR assigned_parolee_id = ''
  THEN
    RAISE EXCEPTION 'tracker_not_authorized'
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.location_logs (
    tracker_id,
    parolee_id,
    latitude,
    longitude,
    accuracy,
    speed,
    battery_level
  )
  VALUES (
    p_tracker_id,
    assigned_parolee_id,
    p_latitude,
    p_longitude,
    p_accuracy,
    p_speed,
    p_battery_level
  );

  UPDATE public.gps_trackers
  SET battery_level = p_battery_level,
      last_seen_at = now(),
      updated_at = now()
  WHERE id = p_tracker_id;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_record_tracker_location(
  text, text, double precision, double precision, double precision, double precision, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_record_tracker_location(
  text, text, double precision, double precision, double precision, double precision, integer
) TO service_role;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'gps_trackers'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.gps_trackers';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
