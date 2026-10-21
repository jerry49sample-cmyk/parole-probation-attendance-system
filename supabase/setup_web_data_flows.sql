-- Adds role-scoped activity access and transactional tracker /
-- manual-attendance operations shared by the web and Flutter apps.
-- It is additive and is not applied automatically.
-- Run setup_shared_officer_trackers.sql after this file to enable shared
-- officer inventory and audited tracker-status updates.
--
-- Run after setup_profiles.sql, setup_access_policies.sql, and
-- setup_activity_attendance.sql and setup_tracking_audit.sql.
-- Review the live schema before applying.

DO $$
DECLARE
  missing_columns text;
BEGIN
  SELECT string_agg(required.table_name || '.' || required.column_name, ', ')
  INTO missing_columns
  FROM (VALUES
    ('activities', 'id'),
    ('activities', 'title'),
    ('activities', 'activity_type'),
    ('activities', 'description'),
    ('activities', 'location_name'),
    ('activities', 'start_time'),
    ('activities', 'end_time'),
    ('activities', 'assigned_officer_id'),
    ('activities', 'assigned_parolee_ids'),
    ('activities', 'status'),
    ('activity_attendance_records', 'id'),
    ('activity_attendance_records', 'activity_id'),
    ('activity_attendance_records', 'parolee_id'),
    ('activity_attendance_records', 'parolee_name'),
    ('activity_attendance_records', 'officer_id'),
    ('activity_attendance_records', 'status'),
    ('activity_attendance_records', 'scanned_at'),
    ('activity_attendance_records', 'verified_by_officer'),
    ('activity_attendance_records', 'ticket_timestamp'),
    ('activity_attendance_records', 'activity_title'),
    ('gps_trackers', 'id'),
    ('gps_trackers', 'device_id'),
    ('gps_trackers', 'device_name'),
    ('gps_trackers', 'device_type'),
    ('gps_trackers', 'serial_number'),
    ('gps_trackers', 'parolee_id'),
    ('gps_trackers', 'parolee_name'),
    ('gps_trackers', 'status'),
    ('gps_trackers', 'battery_level'),
    ('gps_trackers', 'assigned_at'),
    ('profiles', 'id'),
    ('profiles', 'role'),
    ('profiles', 'is_active'),
    ('profiles', 'full_name'),
    ('profiles', 'officer_id'),
    ('tracking_audit_logs', 'id'),
    ('tracking_audit_logs', 'action'),
    ('tracking_audit_logs', 'resource_type'),
    ('tracking_audit_logs', 'resource_id'),
    ('tracking_audit_logs', 'parolee_id'),
    ('tracking_audit_logs', 'actor_id'),
    ('tracking_audit_logs', 'actor_role'),
    ('tracking_audit_logs', 'metadata'),
    ('tracking_audit_logs', 'created_at')
  ) AS required(table_name, column_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns AS actual
    WHERE actual.table_schema = 'public'
      AND actual.table_name = required.table_name
      AND actual.column_name = required.column_name
  );

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'Web data-flow setup stopped; required columns are missing: %',
      missing_columns;
  END IF;

  IF to_regprocedure('public.ppa_current_role()') IS NULL
    OR to_regprocedure('public.ppa_is_assigned_officer(text)') IS NULL
  THEN
    RAISE EXCEPTION
      'Web data-flow setup requires setup_access_policies.sql to be applied first.';
  END IF;
END
$$;

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.activities TO authenticated;
GRANT INSERT (
  title,
  description,
  activity_type,
  location_name,
  start_time,
  end_time,
  assigned_officer_id,
  assigned_parolee_ids,
  status
) ON public.activities TO authenticated;
GRANT UPDATE (status) ON public.activities TO authenticated;

DROP POLICY IF EXISTS ppa_web_activities_read ON public.activities;
CREATE POLICY ppa_web_activities_read ON public.activities
  FOR SELECT TO authenticated
  USING (
    public.ppa_current_role() = 'admin'
    OR (
      public.ppa_current_role() = 'officer'
      AND assigned_officer_id::text = auth.uid()::text
    )
    OR (
      public.ppa_current_role() = 'parolee'
      AND coalesce(to_jsonb(assigned_parolee_ids) ? auth.uid()::text, false)
    )
  );

DROP POLICY IF EXISTS ppa_web_activities_insert ON public.activities;
CREATE POLICY ppa_web_activities_insert ON public.activities
  FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'admin'
    OR (
      public.ppa_current_role() = 'officer'
      AND assigned_officer_id::text = auth.uid()::text
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(
          coalesce(to_jsonb(assigned_parolee_ids), '[]'::jsonb)
        ) AS assigned(parolee_id)
        WHERE NOT public.ppa_is_assigned_officer(assigned.parolee_id)
      )
    )
  );

DROP POLICY IF EXISTS ppa_web_activities_update ON public.activities;
CREATE POLICY ppa_web_activities_update ON public.activities
  FOR UPDATE TO authenticated
  USING (
    public.ppa_current_role() = 'admin'
    OR (
      public.ppa_current_role() = 'officer'
      AND assigned_officer_id::text = auth.uid()::text
    )
  )
  WITH CHECK (
    public.ppa_current_role() = 'admin'
    OR (
      public.ppa_current_role() = 'officer'
      AND assigned_officer_id::text = auth.uid()::text
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(
          coalesce(to_jsonb(assigned_parolee_ids), '[]'::jsonb)
        ) AS assigned(parolee_id)
        WHERE NOT public.ppa_is_assigned_officer(assigned.parolee_id)
      )
    )
  );

CREATE OR REPLACE FUNCTION public.ppa_mark_activity_attendance(
  p_activity_id text,
  p_parolee_id text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, ppa_private, pg_temp
AS $$
DECLARE
  v_user_id text := auth.uid()::text;
  v_role text;
  v_is_active boolean;
  v_parolee_name text;
  v_activity public.activities%ROWTYPE;
  v_record public.activity_attendance_records%ROWTYPE;
  v_status text := lower(trim(coalesce(p_status, '')));
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sign in before recording activity attendance';
  END IF;

  SELECT lower(profile.role::text), coalesce(profile.is_active, false)
  INTO v_role, v_is_active
  FROM public.profiles AS profile
  WHERE profile.id::text = v_user_id;

  IF v_role <> 'officer' OR NOT coalesce(v_is_active, false) THEN
    RAISE EXCEPTION 'Only an active officer can mark activity attendance';
  END IF;
  IF v_status NOT IN ('present', 'absent', 'late') THEN
    RAISE EXCEPTION 'Invalid activity attendance status';
  END IF;

  SELECT activity.*
  INTO v_activity
  FROM public.activities AS activity
  WHERE activity.id::text = p_activity_id
  FOR UPDATE;

  IF NOT FOUND
    OR v_activity.assigned_officer_id::text <> v_user_id
    OR lower(coalesce(v_activity.status::text, '')) IN ('missed', 'completed')
    OR NOT coalesce(to_jsonb(v_activity.assigned_parolee_ids) ? p_parolee_id, false)
  THEN
    RAISE EXCEPTION 'This parolee is not assigned to an available activity you manage';
  END IF;

  SELECT profile.full_name
  INTO v_parolee_name
  FROM public.profiles AS profile
  WHERE profile.id::text = p_parolee_id
    AND lower(profile.role::text) = 'parolee'
    AND profile.officer_id::text = v_user_id
    AND coalesce(profile.is_active, false);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The assigned parolee account is not active or is outside your caseload';
  END IF;

  INSERT INTO public.activity_attendance_records (
    activity_id,
    parolee_id,
    parolee_name,
    officer_id,
    status,
    scanned_at,
    verified_by_officer,
    ticket_timestamp,
    activity_title
  )
  VALUES (
    p_activity_id,
    p_parolee_id,
    coalesce(nullif(trim(v_parolee_name), ''), 'Parolee'),
    v_user_id,
    v_status,
    now(),
    true,
    now(),
    v_activity.title::text
  )
  ON CONFLICT (activity_id, parolee_id) DO UPDATE
  SET parolee_name = EXCLUDED.parolee_name,
      officer_id = EXCLUDED.officer_id,
      status = EXCLUDED.status,
      scanned_at = EXCLUDED.scanned_at,
      verified_by_officer = true,
      ticket_timestamp = EXCLUDED.ticket_timestamp,
      activity_title = EXCLUDED.activity_title
  RETURNING * INTO v_record;

  RETURN to_jsonb(v_record);
END
$$;

REVOKE ALL ON FUNCTION public.ppa_mark_activity_attendance(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_mark_activity_attendance(text, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.ppa_assign_tracker(
  p_tracker_id text,
  p_parolee_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id text := auth.uid()::text;
  v_role text;
  v_is_active boolean;
  v_parolee_name text;
  v_tracker_parolee_id text;
BEGIN
  SELECT lower(profile.role::text), coalesce(profile.is_active, false)
  INTO v_role, v_is_active
  FROM public.profiles AS profile
  WHERE profile.id::text = v_user_id;

  IF v_role NOT IN ('officer', 'admin')
    OR NOT coalesce(v_is_active, false)
  THEN
    RAISE EXCEPTION 'Only an active officer or administrator can assign GPS trackers';
  END IF;
  IF nullif(trim(coalesce(p_tracker_id, '')), '') IS NULL
    OR nullif(trim(coalesce(p_parolee_id, '')), '') IS NULL
  THEN
    RAISE EXCEPTION 'A tracker and parolee are required';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('ppa_assign_tracker'),
    hashtext(p_parolee_id)
  );

  IF v_role = 'officer'
    AND NOT public.ppa_is_assigned_officer(p_parolee_id)
  THEN
    RAISE EXCEPTION 'The parolee is outside your assigned caseload';
  END IF;

  SELECT profile.full_name
  INTO v_parolee_name
  FROM public.profiles AS profile
  WHERE profile.id::text = p_parolee_id
    AND lower(profile.role::text) = 'parolee'
    AND coalesce(profile.is_active, false);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The parolee account is not active';
  END IF;

  SELECT tracker.parolee_id::text
  INTO v_tracker_parolee_id
  FROM public.gps_trackers AS tracker
  WHERE tracker.id::text = p_tracker_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GPS tracker not found';
  END IF;

  IF v_tracker_parolee_id IS NOT NULL
    AND v_tracker_parolee_id <> p_parolee_id
  THEN
    INSERT INTO public.tracking_audit_logs (
      action, resource_type, resource_id, parolee_id, actor_id, actor_role, metadata
    )
    VALUES (
      'device_unassigned',
      'device',
      p_tracker_id,
      v_tracker_parolee_id,
      v_user_id,
      v_role,
      jsonb_build_object(
        'reason', 'shared_tracker_transferred',
        'assigned_to_parolee_id', p_parolee_id
      )
    );
  END IF;

  WITH cleared_trackers AS (
    UPDATE public.gps_trackers
    SET parolee_id = NULL,
        parolee_name = NULL,
        status = 'unassigned',
        assigned_at = NULL,
        updated_at = now()
    WHERE parolee_id::text = p_parolee_id
      AND id::text <> p_tracker_id
    RETURNING id, parolee_id
  )
  INSERT INTO public.tracking_audit_logs (
    action,
    resource_type,
    resource_id,
    parolee_id,
    actor_id,
    actor_role,
    metadata
  )
  SELECT
    'device_unassigned',
    'device',
    cleared_trackers.id::text,
    cleared_trackers.parolee_id::text,
    v_user_id,
    v_role,
    jsonb_build_object(
      'reason', 'reassigned_to_another_tracker',
      'assigned_tracker_id', p_tracker_id
    )
  FROM cleared_trackers;

  UPDATE public.gps_trackers
  SET parolee_id = p_parolee_id,
      parolee_name = v_parolee_name,
      status = 'active',
      assigned_at = now(),
      updated_at = now()
  WHERE id::text = p_tracker_id;

  INSERT INTO public.tracking_audit_logs (
    action,
    resource_type,
    resource_id,
    parolee_id,
    actor_id,
    actor_role,
    metadata
  )
  VALUES (
    'device_assigned',
    'device',
    p_tracker_id,
    p_parolee_id,
    v_user_id,
    v_role,
    jsonb_build_object('previous_parolee_id', v_tracker_parolee_id)
  );
END
$$;

CREATE OR REPLACE FUNCTION public.ppa_unassign_tracker(p_tracker_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id text := auth.uid()::text;
  v_role text;
  v_is_active boolean;
  v_parolee_id text;
BEGIN
  SELECT lower(profile.role::text), coalesce(profile.is_active, false)
  INTO v_role, v_is_active
  FROM public.profiles AS profile
  WHERE profile.id::text = v_user_id;

  IF v_role NOT IN ('officer', 'admin')
    OR NOT coalesce(v_is_active, false)
  THEN
    RAISE EXCEPTION 'Only an active officer or administrator can unassign GPS trackers';
  END IF;

  SELECT tracker.parolee_id::text
  INTO v_parolee_id
  FROM public.gps_trackers AS tracker
  WHERE tracker.id::text = p_tracker_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GPS tracker not found';
  END IF;
  IF v_parolee_id IS NOT NULL
    AND v_role <> 'admin'
    AND NOT public.ppa_is_assigned_officer(v_parolee_id)
  THEN
    RAISE EXCEPTION 'GPS tracker is assigned outside your caseload';
  END IF;

  UPDATE public.gps_trackers
  SET parolee_id = NULL,
      parolee_name = NULL,
      status = 'unassigned',
      assigned_at = NULL,
      updated_at = now()
  WHERE id::text = p_tracker_id;

  INSERT INTO public.tracking_audit_logs (
    action,
    resource_type,
    resource_id,
    parolee_id,
    actor_id,
    actor_role
  )
  VALUES (
    'device_unassigned',
    'device',
    p_tracker_id,
    v_parolee_id,
    v_user_id,
    v_role
  );
END
$$;

REVOKE ALL ON FUNCTION public.ppa_assign_tracker(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ppa_unassign_tracker(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_assign_tracker(text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_unassign_tracker(text)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'activities'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.activities;
    END IF;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
