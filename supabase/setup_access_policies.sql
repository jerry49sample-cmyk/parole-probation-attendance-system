-- Apply after setup_location_logs.sql and setup_attendance_records.sql.
-- This script changes access controls, not existing records. Review the
-- profile columns and role values against the live project before running.
-- GPS firmware using only the public anon key will intentionally be denied;
-- it needs per-device authentication before it can write location data.

DO $$
DECLARE
  missing_columns text;
BEGIN
  SELECT string_agg(format('%s.%s', required.table_name, required.column_name), ', ')
  INTO missing_columns
  FROM (VALUES
    ('profiles', 'id'),
    ('profiles', 'role'),
    ('profiles', 'officer_id'),
    ('profiles', 'is_active'),
    ('profiles', 'email'),
    ('profiles', 'full_name'),
    ('profiles', 'phone'),
    ('profiles', 'avatar_initials'),
    ('profiles', 'created_at'),
    ('profiles', 'case_number'),
    ('profiles', 'department'),
    ('profiles', 'supervision_start_date'),
    ('profiles', 'supervision_end_date'),
    ('profiles', 'supervision_is_suspended'),
    ('attendance_records', 'ticket_id'),
    ('attendance_records', 'parolee_id'),
    ('attendance_records', 'officer_id'),
    ('attendance_records', 'status'),
    ('attendance_records', 'check_in_time'),
    ('attendance_records', 'location'),
    ('attendance_records', 'verified'),
    ('attendance_records', 'created_at'),
    ('attendance_records', 'created_by'),
    ('location_logs', 'tracker_id'),
    ('location_logs', 'parolee_id'),
    ('location_logs', 'latitude'),
    ('location_logs', 'longitude'),
    ('location_logs', 'accuracy'),
    ('location_logs', 'speed'),
    ('location_logs', 'battery_level'),
    ('location_logs', 'created_at'),
    ('gps_trackers', 'id'),
    ('gps_trackers', 'device_id'),
    ('gps_trackers', 'device_name'),
    ('gps_trackers', 'device_type'),
    ('gps_trackers', 'serial_number'),
    ('gps_trackers', 'parolee_id'),
    ('gps_trackers', 'parolee_name'),
    ('gps_trackers', 'status'),
    ('gps_trackers', 'battery_level'),
    ('gps_trackers', 'last_seen_at'),
    ('gps_trackers', 'assigned_at'),
    ('gps_trackers', 'created_at'),
    ('gps_trackers', 'updated_at'),
    ('gps_tracker_credentials', 'tracker_id'),
    ('gps_tracker_credentials', 'token_hash'),
    ('gps_tracker_credentials', 'is_active'),
    ('geofences', 'id'),
    ('geofences', 'parolee_id')
  ) AS required(table_name, column_name)
  LEFT JOIN information_schema.columns AS actual
    ON actual.table_schema = 'public'
   AND actual.table_name = required.table_name
   AND actual.column_name = required.column_name
  WHERE actual.column_name IS NULL;

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'Access-policy setup stopped: required public columns are missing: %',
      missing_columns;
  END IF;
END
$$;

-- Provision only low-privilege, unassigned roles from signup metadata.
-- Administrator privileges must be assigned through a trusted Supabase path.
CREATE OR REPLACE FUNCTION public.ppa_create_profile_from_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  requested_role text;
BEGIN
  requested_role := lower(coalesce(NEW.raw_user_meta_data ->> 'role', ''));
  IF requested_role NOT IN ('officer', 'parolee') THEN
    RAISE EXCEPTION 'Self-registration is limited to officer or parolee accounts';
  END IF;

  INSERT INTO public.profiles (
    id,
    email,
    full_name,
    role,
    phone,
    created_at,
    officer_id,
    is_active,
    case_number,
    department,
    supervision_start_date,
    supervision_end_date,
    supervision_is_suspended
  )
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(nullif(trim(NEW.raw_user_meta_data ->> 'full_name'), ''), NEW.email),
    (
      jsonb_populate_record(
        NULL::public.profiles,
        jsonb_build_object('role', requested_role)
      )
    ).role,
    nullif(trim(NEW.raw_user_meta_data ->> 'phone'), ''),
    now(),
    NULL,
    true,
    NULL,
    NULL,
    NULL,
    NULL,
    false
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_create_profile_from_auth_user() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS ppa_create_profile_after_signup ON auth.users;
CREATE TRIGGER ppa_create_profile_after_signup
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.ppa_create_profile_from_auth_user();

CREATE OR REPLACE FUNCTION public.ppa_current_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT lower(p.role::text)
  FROM public.profiles AS p
  WHERE p.id::text = auth.uid()::text
    AND coalesce(p.is_active, false)
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.ppa_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(public.ppa_current_role() = 'admin', false)
$$;

CREATE OR REPLACE FUNCTION public.ppa_assigned_officer_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p.officer_id::text
  FROM public.profiles AS p
  WHERE p.id::text = auth.uid()::text
    AND lower(p.role::text) = 'parolee'
    AND coalesce(p.is_active, false)
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.ppa_is_assigned_officer(target_parolee_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS parolee
    JOIN public.profiles AS officer
      ON officer.id::text = parolee.officer_id::text
    WHERE parolee.id::text = target_parolee_id
      AND lower(parolee.role::text) = 'parolee'
      AND officer.id::text = auth.uid()::text
      AND lower(officer.role::text) = 'officer'
      AND coalesce(officer.is_active, false)
  )
$$;

CREATE OR REPLACE FUNCTION public.ppa_can_access_parolee(target_parolee_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    public.ppa_is_admin()
    OR (
      target_parolee_id = auth.uid()::text
      AND public.ppa_current_role() = 'parolee'
    )
    OR public.ppa_is_assigned_officer(target_parolee_id),
    false
  )
$$;

-- Officers can manage unassigned hardware and trackers assigned within their
-- caseload. Parolees may read only a tracker assigned to their own profile.
CREATE OR REPLACE FUNCTION public.ppa_can_manage_tracker(target_parolee_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    public.ppa_is_admin()
    OR (
      public.ppa_current_role() = 'officer'
      AND (
        target_parolee_id IS NULL
        OR public.ppa_is_assigned_officer(target_parolee_id)
      )
    ),
    false
  )
$$;

CREATE OR REPLACE FUNCTION public.ppa_can_read_profile(target_profile_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    public.ppa_is_admin()
    OR target_profile_id = auth.uid()::text
    OR public.ppa_is_assigned_officer(target_profile_id)
    OR EXISTS (
      SELECT 1
      FROM public.profiles AS parolee
      WHERE parolee.id::text = auth.uid()::text
        AND lower(parolee.role::text) = 'parolee'
        AND parolee.officer_id::text = target_profile_id
        AND coalesce(parolee.is_active, false)
    ),
    false
  )
$$;

CREATE OR REPLACE FUNCTION public.ppa_can_manage_profile(target_profile_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    public.ppa_is_admin()
    OR target_profile_id = auth.uid()::text
    OR public.ppa_is_assigned_officer(target_profile_id),
    false
  )
$$;

CREATE OR REPLACE FUNCTION public.ppa_list_unassigned_parolees()
RETURNS TABLE (id text, full_name text, case_number text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.ppa_current_role() IS DISTINCT FROM 'officer' THEN
    RAISE EXCEPTION 'Only active officers can view unassigned parolees';
  END IF;

  RETURN QUERY
  SELECT p.id::text, p.full_name::text, p.case_number::text
  FROM public.profiles AS p
  WHERE lower(p.role::text) = 'parolee'
    AND coalesce(p.is_active, false)
    AND p.officer_id IS NULL
  ORDER BY p.full_name NULLS LAST, p.id;
END
$$;

CREATE OR REPLACE FUNCTION public.ppa_assign_parolee_to_self(target_parolee_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  officer_profile_id text := auth.uid()::text;
BEGIN
  IF officer_profile_id IS NULL
    OR public.ppa_current_role() IS DISTINCT FROM 'officer'
  THEN
    RAISE EXCEPTION 'Only active officers can assign parolees to themselves';
  END IF;

  PERFORM set_config('ppa.self_assign_parolee_id', coalesce(target_parolee_id, ''), true);

  UPDATE public.profiles
  SET officer_id = officer_profile_id
  WHERE id::text = target_parolee_id
    AND lower(role::text) = 'parolee'
    AND coalesce(is_active, false)
    AND officer_id IS NULL;

  IF NOT FOUND THEN
    PERFORM set_config('ppa.self_assign_parolee_id', '', true);
    RAISE EXCEPTION 'Parolee is not available for assignment';
  END IF;

  PERFORM set_config('ppa.self_assign_parolee_id', '', true);
END
$$;

-- Prevent a user or assigned officer from escalating roles, reassigning
-- accounts, changing case identifiers, or disabling accounts. The self-claim
-- RPC above can change officer_id only for one active, unassigned parolee.
CREATE OR REPLACE FUNCTION public.ppa_protect_profile_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.ppa_is_admin() THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
    OR NEW.email IS DISTINCT FROM OLD.email
    OR NEW.role IS DISTINCT FROM OLD.role
    OR (
      NEW.officer_id IS DISTINCT FROM OLD.officer_id
      AND NOT (
        coalesce(current_setting('ppa.self_assign_parolee_id', true), '') = OLD.id::text
        AND public.ppa_current_role() = 'officer'
        AND lower(OLD.role::text) = 'parolee'
        AND OLD.officer_id IS NULL
        AND NEW.officer_id::text = auth.uid()::text
      )
    )
    OR NEW.is_active IS DISTINCT FROM OLD.is_active
    OR NEW.case_number IS DISTINCT FROM OLD.case_number
    OR NEW.department IS DISTINCT FROM OLD.department
    OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'Only an administrator can change protected profile fields';
  END IF;

  IF (
      NEW.supervision_start_date IS DISTINCT FROM OLD.supervision_start_date
      OR NEW.supervision_end_date IS DISTINCT FROM OLD.supervision_end_date
      OR NEW.supervision_is_suspended IS DISTINCT FROM OLD.supervision_is_suspended
    )
    AND NOT (
      public.ppa_current_role() = 'officer'
      AND public.ppa_is_assigned_officer(OLD.id::text)
    )
  THEN
    RAISE EXCEPTION 'Only the assigned officer or an administrator can change supervision';
  END IF;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS ppa_protect_profile_fields ON public.profiles;
CREATE TRIGGER ppa_protect_profile_fields
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.ppa_protect_profile_fields();

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.location_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.geofences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gps_trackers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gps_tracker_credentials ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.attendance_records FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.location_logs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.geofences FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.gps_trackers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.gps_tracker_credentials FROM PUBLIC, anon, authenticated;

GRANT SELECT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT SELECT ON TABLE public.attendance_records TO authenticated;
GRANT INSERT (ticket_id, parolee_id, officer_id, status, location)
  ON TABLE public.attendance_records TO authenticated;
GRANT UPDATE (status, verified)
  ON TABLE public.attendance_records TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.attendance_records_id_seq TO authenticated;
GRANT SELECT ON TABLE public.location_logs TO authenticated;
GRANT INSERT (tracker_id, parolee_id, latitude, longitude, accuracy, speed, battery_level)
  ON TABLE public.location_logs TO authenticated;
GRANT SELECT ON TABLE public.gps_trackers TO authenticated;
GRANT INSERT (id, device_id, device_name, device_type, serial_number)
  ON TABLE public.gps_trackers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.geofences TO authenticated;

DO $$
DECLARE
  sequence_name text;
BEGIN
  sequence_name := pg_get_serial_sequence('public.location_logs', 'id');
  IF sequence_name IS NOT NULL THEN
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO authenticated', sequence_name);
  END IF;

  sequence_name := pg_get_serial_sequence('public.geofences', 'id');
  IF sequence_name IS NOT NULL THEN
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO authenticated', sequence_name);
  END IF;
END
$$;

REVOKE ALL ON FUNCTION public.ppa_current_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_assigned_officer_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_is_assigned_officer(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_can_access_parolee(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_can_manage_tracker(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_can_read_profile(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_can_manage_profile(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_list_unassigned_parolees() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ppa_assign_parolee_to_self(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ppa_current_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_assigned_officer_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_is_assigned_officer(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_can_access_parolee(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_can_manage_tracker(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_can_read_profile(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_can_manage_profile(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_list_unassigned_parolees() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_assign_parolee_to_self(text) TO authenticated;

DROP POLICY IF EXISTS ppa_profiles_read ON public.profiles;
DROP POLICY IF EXISTS ppa_profiles_read_limit ON public.profiles;
CREATE POLICY ppa_profiles_read ON public.profiles
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (public.ppa_can_read_profile(id::text));
CREATE POLICY ppa_profiles_read_limit ON public.profiles
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.ppa_can_read_profile(id::text));

DROP POLICY IF EXISTS ppa_profiles_self_register ON public.profiles;
DROP POLICY IF EXISTS ppa_profiles_self_register_limit ON public.profiles;

DROP POLICY IF EXISTS ppa_profiles_update ON public.profiles;
DROP POLICY IF EXISTS ppa_profiles_update_limit ON public.profiles;
CREATE POLICY ppa_profiles_update ON public.profiles
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (public.ppa_can_manage_profile(id::text))
  WITH CHECK (public.ppa_can_manage_profile(id::text));
CREATE POLICY ppa_profiles_update_limit ON public.profiles
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.ppa_can_manage_profile(id::text))
  WITH CHECK (public.ppa_can_manage_profile(id::text));

DROP POLICY IF EXISTS ppa_attendance_read ON public.attendance_records;
DROP POLICY IF EXISTS ppa_attendance_read_limit ON public.attendance_records;
CREATE POLICY ppa_attendance_read ON public.attendance_records
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));
CREATE POLICY ppa_attendance_read_limit ON public.attendance_records
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));

DROP POLICY IF EXISTS ppa_attendance_insert ON public.attendance_records;
DROP POLICY IF EXISTS ppa_attendance_insert_limit ON public.attendance_records;
CREATE POLICY ppa_attendance_insert ON public.attendance_records
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'parolee'
    AND parolee_id::text = auth.uid()::text
    AND officer_id::text = public.ppa_assigned_officer_id()
    AND created_by = auth.uid()
    AND lower(status::text) = 'checkedin'
  );
CREATE POLICY ppa_attendance_insert_limit ON public.attendance_records
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'parolee'
    AND parolee_id::text = auth.uid()::text
    AND officer_id::text = public.ppa_assigned_officer_id()
    AND created_by = auth.uid()
    AND lower(status::text) = 'checkedin'
  );

DROP POLICY IF EXISTS ppa_attendance_update ON public.attendance_records;
DROP POLICY IF EXISTS ppa_attendance_update_limit ON public.attendance_records;
CREATE POLICY ppa_attendance_update ON public.attendance_records
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  )
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );
CREATE POLICY ppa_attendance_update_limit ON public.attendance_records
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  )
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );

DROP POLICY IF EXISTS ppa_locations_read ON public.location_logs;
DROP POLICY IF EXISTS ppa_locations_read_limit ON public.location_logs;
CREATE POLICY ppa_locations_read ON public.location_logs
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));
CREATE POLICY ppa_locations_read_limit ON public.location_logs
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));

DROP POLICY IF EXISTS ppa_locations_phone_insert ON public.location_logs;
DROP POLICY IF EXISTS ppa_locations_phone_insert_limit ON public.location_logs;
CREATE POLICY ppa_locations_phone_insert ON public.location_logs
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'parolee'
    AND parolee_id::text = auth.uid()::text
    AND tracker_id = 'phone_' || auth.uid()::text
    AND latitude BETWEEN -90 AND 90
    AND longitude BETWEEN -180 AND 180
    AND (accuracy IS NULL OR accuracy BETWEEN 0 AND 10000)
    AND (speed IS NULL OR speed >= 0)
  );
CREATE POLICY ppa_locations_phone_insert_limit ON public.location_logs
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_current_role() = 'parolee'
    AND parolee_id::text = auth.uid()::text
    AND tracker_id = 'phone_' || auth.uid()::text
    AND latitude BETWEEN -90 AND 90
    AND longitude BETWEEN -180 AND 180
    AND (accuracy IS NULL OR accuracy BETWEEN 0 AND 10000)
    AND (speed IS NULL OR speed >= 0)
  );

DROP POLICY IF EXISTS ppa_geofences_read ON public.geofences;
DROP POLICY IF EXISTS ppa_geofences_read_limit ON public.geofences;
CREATE POLICY ppa_geofences_read ON public.geofences
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));
CREATE POLICY ppa_geofences_read_limit ON public.geofences
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.ppa_can_access_parolee(parolee_id::text));

DROP POLICY IF EXISTS ppa_geofences_insert ON public.geofences;
DROP POLICY IF EXISTS ppa_geofences_insert_limit ON public.geofences;
CREATE POLICY ppa_geofences_insert ON public.geofences
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );
CREATE POLICY ppa_geofences_insert_limit ON public.geofences
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );

DROP POLICY IF EXISTS ppa_geofences_update ON public.geofences;
DROP POLICY IF EXISTS ppa_geofences_update_limit ON public.geofences;
CREATE POLICY ppa_geofences_update ON public.geofences
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  )
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );

DROP POLICY IF EXISTS ppa_geofences_delete ON public.geofences;
DROP POLICY IF EXISTS ppa_geofences_delete_limit ON public.geofences;
CREATE POLICY ppa_geofences_delete ON public.geofences
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );
CREATE POLICY ppa_geofences_delete_limit ON public.geofences
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );
CREATE POLICY ppa_geofences_update_limit ON public.geofences
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  )
  WITH CHECK (
    public.ppa_is_admin()
    OR public.ppa_is_assigned_officer(parolee_id::text)
  );

DROP POLICY IF EXISTS ppa_gps_trackers_read ON public.gps_trackers;
DROP POLICY IF EXISTS ppa_gps_trackers_read_limit ON public.gps_trackers;
CREATE POLICY ppa_gps_trackers_read ON public.gps_trackers
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_can_access_parolee(parolee_id::text)
    OR (
      parolee_id IS NULL
      AND public.ppa_current_role() = 'officer'
    )
  );
CREATE POLICY ppa_gps_trackers_read_limit ON public.gps_trackers
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (
    public.ppa_is_admin()
    OR public.ppa_can_access_parolee(parolee_id::text)
    OR (
      parolee_id IS NULL
      AND public.ppa_current_role() = 'officer'
    )
  );

DROP POLICY IF EXISTS ppa_gps_trackers_insert ON public.gps_trackers;
DROP POLICY IF EXISTS ppa_gps_trackers_insert_limit ON public.gps_trackers;
CREATE POLICY ppa_gps_trackers_insert ON public.gps_trackers
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (public.ppa_can_manage_tracker(parolee_id::text));
CREATE POLICY ppa_gps_trackers_insert_limit ON public.gps_trackers
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.ppa_can_manage_tracker(parolee_id::text));

DROP POLICY IF EXISTS ppa_gps_trackers_update ON public.gps_trackers;
DROP POLICY IF EXISTS ppa_gps_trackers_update_limit ON public.gps_trackers;
CREATE POLICY ppa_gps_trackers_update ON public.gps_trackers
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (public.ppa_can_manage_tracker(parolee_id::text))
  WITH CHECK (public.ppa_can_manage_tracker(parolee_id::text));
CREATE POLICY ppa_gps_trackers_update_limit ON public.gps_trackers
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.ppa_can_manage_tracker(parolee_id::text))
  WITH CHECK (public.ppa_can_manage_tracker(parolee_id::text));

NOTIFY pgrst, 'reload schema';
