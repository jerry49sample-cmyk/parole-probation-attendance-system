-- Shares tracker hardware inventory between active officers while keeping
-- parolee identity and location history scoped to the assigned caseload.
-- Run after setup_access_policies.sql, setup_tracking_audit.sql, and
-- setup_web_data_flows.sql.

DO $$
BEGIN
  IF to_regclass('public.gps_trackers') IS NULL THEN
    RAISE EXCEPTION
      'Shared tracker setup requires public.gps_trackers; run setup_esp32_trackers.sql first.';
  END IF;
  IF to_regclass('public.tracking_audit_logs') IS NULL THEN
    RAISE EXCEPTION
      'Shared tracker setup requires public.tracking_audit_logs; run setup_tracking_audit.sql first.';
  END IF;
  IF to_regclass('public.profiles') IS NULL THEN
    RAISE EXCEPTION
      'Shared tracker setup requires public.profiles and its officer_id column.';
  END IF;
END
$$;

-- Assignment changes must use the audited RPC. Tracker status is also changed
-- through an audited RPC so one officer can maintain shared hardware safely.
REVOKE UPDATE ON TABLE public.gps_trackers
  FROM PUBLIC, anon, authenticated;
REVOKE UPDATE (
  parolee_id, parolee_name, status, assigned_at, updated_at
) ON TABLE public.gps_trackers FROM PUBLIC, anon, authenticated;

-- Keep tracker creation limited to unassigned inventory records.
REVOKE INSERT ON TABLE public.gps_trackers
  FROM PUBLIC, anon, authenticated;
REVOKE INSERT (
  id, device_id, device_name, device_type, serial_number,
  parolee_id, parolee_name, status, battery_level, last_seen_at,
  assigned_at, created_at, updated_at
) ON TABLE public.gps_trackers FROM PUBLIC, anon, authenticated;
GRANT INSERT (id, device_id, device_name, device_type, serial_number)
  ON TABLE public.gps_trackers TO authenticated;

CREATE OR REPLACE FUNCTION public.ppa_list_shared_trackers()
RETURNS TABLE (
  id text,
  device_id text,
  device_name text,
  device_type text,
  serial_number text,
  parolee_id text,
  parolee_name text,
  has_hidden_assignment boolean,
  status text,
  battery_level integer,
  last_seen_at timestamptz,
  assigned_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text := public.ppa_current_role();
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('officer', 'admin') THEN
    RAISE EXCEPTION 'Only active officers and administrators can view tracker inventory';
  END IF;

  RETURN QUERY
  SELECT
    tracker.id,
    tracker.device_id,
    tracker.device_name,
    tracker.device_type,
    tracker.serial_number,
    CASE
      WHEN tracker.parolee_id IS NULL
        OR v_role = 'admin'
        OR public.ppa_is_assigned_officer(tracker.parolee_id::text)
      THEN tracker.parolee_id::text
      ELSE NULL
    END,
    CASE
      WHEN tracker.parolee_id IS NULL
        OR v_role = 'admin'
        OR public.ppa_is_assigned_officer(tracker.parolee_id::text)
      THEN tracker.parolee_name
      ELSE NULL
    END,
    tracker.parolee_id IS NOT NULL
      AND v_role <> 'admin'
      AND NOT public.ppa_is_assigned_officer(tracker.parolee_id::text),
    tracker.status,
    tracker.battery_level::integer,
    tracker.last_seen_at,
    tracker.assigned_at,
    tracker.created_at,
    tracker.updated_at
  FROM public.gps_trackers AS tracker
  ORDER BY tracker.id;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_list_shared_trackers()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ppa_list_shared_trackers()
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

  -- A shared tracker may be transferred from another caseload. Record the
  -- release separately; the assignment and both audit events are atomic.
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

REVOKE ALL ON FUNCTION public.ppa_assign_tracker(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_assign_tracker(text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.ppa_update_tracker_status(
  p_tracker_id text,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id text := auth.uid()::text;
  v_role text := public.ppa_current_role();
  v_parolee_id text;
  v_previous_status text;
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('officer', 'admin') THEN
    RAISE EXCEPTION 'Only active officers and administrators can edit tracker status';
  END IF;
  IF p_status IS NULL
    OR p_status NOT IN ('active', 'inactive', 'offline', 'maintenance')
  THEN
    RAISE EXCEPTION 'Invalid tracker status';
  END IF;

  SELECT tracker.parolee_id::text, tracker.status
  INTO v_parolee_id, v_previous_status
  FROM public.gps_trackers AS tracker
  WHERE tracker.id::text = p_tracker_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GPS tracker not found';
  END IF;

  IF v_previous_status IS DISTINCT FROM p_status THEN
    UPDATE public.gps_trackers
    SET status = p_status,
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
      'device_status_updated',
      'device',
      p_tracker_id,
      v_parolee_id,
      v_user_id,
      v_role,
      jsonb_build_object(
        'previous_status', v_previous_status,
        'new_status', p_status
      )
    );
  END IF;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_update_tracker_status(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_update_tracker_status(text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
