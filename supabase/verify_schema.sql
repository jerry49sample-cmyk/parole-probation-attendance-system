-- Read-only schema check for the React app and GPS firmware.
-- Run this in Supabase Dashboard > SQL Editor. No data or schema is changed.

WITH required_columns(table_name, column_name) AS (
  VALUES
    ('profiles', 'id'),
    ('profiles', 'role'),
    ('profiles', 'officer_id'),
    ('profiles', 'is_active'),
    ('profiles', 'email'),
    ('profiles', 'full_name'),
    ('profiles', 'phone'),
    ('profiles', 'avatar_initials'),
    ('profiles', 'case_number'),
    ('profiles', 'department'),
    ('profiles', 'supervision_start_date'),
    ('profiles', 'supervision_end_date'),
    ('profiles', 'supervision_is_suspended'),
    ('profiles', 'created_at'),
    ('location_logs', 'id'),
    ('location_logs', 'tracker_id'),
    ('location_logs', 'parolee_id'),
    ('location_logs', 'latitude'),
    ('location_logs', 'longitude'),
    ('location_logs', 'accuracy'),
    ('location_logs', 'speed'),
    ('location_logs', 'battery_level'),
    ('location_logs', 'created_at'),
    ('activities', 'id'),
    ('activities', 'title'),
    ('activities', 'description'),
    ('activities', 'activity_type'),
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
    ('attendance_records', 'id'),
    ('attendance_records', 'ticket_id'),
    ('attendance_records', 'parolee_id'),
    ('attendance_records', 'officer_id'),
    ('attendance_records', 'status'),
    ('attendance_records', 'check_in_time'),
    ('attendance_records', 'location'),
    ('attendance_records', 'verified'),
    ('attendance_records', 'created_at'),
    ('attendance_records', 'created_by'),
    ('schedules', 'id'),
    ('schedules', 'parolee_id'),
    ('schedules', 'parolee_name'),
    ('schedules', 'officer_id'),
    ('schedules', 'scheduled_at'),
    ('schedules', 'location'),
    ('schedules', 'type'),
    ('schedules', 'notes'),
    ('schedules', 'created_at'),
    ('notifications', 'id'),
    ('notifications', 'user_id'),
    ('notifications', 'title'),
    ('notifications', 'body'),
    ('notifications', 'type'),
    ('notifications', 'created_at'),
    ('notifications', 'read'),
    ('geofences', 'id'),
    ('geofences', 'parolee_id'),
    ('geofences', 'name'),
    ('geofences', 'latitude'),
    ('geofences', 'longitude'),
    ('geofences', 'radius_meters'),
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
    ('gps_tracker_credentials', 'created_at'),
    ('gps_tracker_credentials', 'rotated_at'),
    ('tracking_audit_logs', 'id'),
    ('tracking_audit_logs', 'action'),
    ('tracking_audit_logs', 'resource_type'),
    ('tracking_audit_logs', 'resource_id'),
    ('tracking_audit_logs', 'parolee_id'),
    ('tracking_audit_logs', 'actor_id'),
    ('tracking_audit_logs', 'actor_role'),
    ('tracking_audit_logs', 'metadata'),
    ('tracking_audit_logs', 'created_at')
),
expected_tables AS (
  SELECT DISTINCT table_name FROM required_columns
),
table_checks AS (
  SELECT
    'table'::text AS check_type,
    format('public.%I', t.table_name) AS object_name,
    CASE
      WHEN to_regclass(format('public.%I', t.table_name)) IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
  FROM expected_tables AS t
),
column_checks AS (
  SELECT
    'column'::text AS check_type,
    format('public.%I.%I', r.table_name, r.column_name) AS object_name,
    CASE
      WHEN c.column_name IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    c.data_type::text AS actual_type
  FROM required_columns AS r
  LEFT JOIN information_schema.columns AS c
    ON c.table_schema = 'public'
   AND c.table_name = r.table_name
   AND c.column_name = r.column_name
),
rls_checks AS (
  SELECT
    'row-level security'::text AS check_type,
    format('public.%I', t.table_name) AS object_name,
    CASE
      WHEN c.oid IS NULL THEN 'TABLE MISSING'
      WHEN c.relrowsecurity THEN 'ENABLED'
      ELSE 'DISABLED'
    END AS status,
    NULL::text AS actual_type
  FROM expected_tables AS t
  LEFT JOIN pg_class AS c
    ON c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
   AND c.relname = t.table_name
   AND c.relkind IN ('r', 'p')
),
primary_key_checks AS (
  SELECT
    'primary key'::text AS check_type,
    format('public.%I(id)', expected.table_name) AS object_name,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_constraint AS constraint_row
        WHERE constraint_row.conrelid = to_regclass(format('public.%I', expected.table_name))
          AND constraint_row.contype = 'p'
          AND pg_get_constraintdef(constraint_row.oid) = 'PRIMARY KEY (id)'
      ) THEN 'OK'
      ELSE 'MISSING'
    END AS status,
    NULL::text AS actual_type
  FROM (VALUES
    ('schedules'),
    ('notifications'),
    ('activity_attendance_records'),
    ('tracking_audit_logs')
  ) AS expected(table_name)
),
realtime_checks AS (
  SELECT
    'realtime publication'::text AS check_type,
    format('supabase_realtime: public.%I', expected.table_name) AS object_name,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = expected.table_name
      ) THEN 'ENABLED'
      ELSE 'NOT ENABLED'
    END AS status,
    NULL::text AS actual_type
  FROM (VALUES
    ('location_logs'),
    ('attendance_records'),
    ('gps_trackers'),
    ('schedules'),
    ('notifications'),
    ('activity_attendance_records')
  ) AS expected(table_name)
),
policy_requirements(table_name, policy_name, command) AS (
  VALUES
    ('profiles', 'ppa_profiles_read_limit', 'SELECT'),
    ('profiles', 'ppa_profiles_update_limit', 'UPDATE'),
    ('attendance_records', 'ppa_attendance_read_limit', 'SELECT'),
    ('attendance_records', 'ppa_attendance_insert_limit', 'INSERT'),
    ('attendance_records', 'ppa_attendance_update_limit', 'UPDATE'),
    ('location_logs', 'ppa_locations_read_limit', 'SELECT'),
    ('location_logs', 'ppa_locations_phone_insert_limit', 'INSERT'),
    ('gps_trackers', 'ppa_gps_trackers_read_limit', 'SELECT'),
    ('gps_trackers', 'ppa_gps_trackers_insert_limit', 'INSERT'),
    ('gps_trackers', 'ppa_gps_trackers_update_limit', 'UPDATE'),
    ('geofences', 'ppa_geofences_read_limit', 'SELECT'),
    ('geofences', 'ppa_geofences_insert_limit', 'INSERT'),
    ('geofences', 'ppa_geofences_update_limit', 'UPDATE'),
    ('geofences', 'ppa_geofences_delete_limit', 'DELETE'),
    ('schedules', 'ppa_schedules_read_limit', 'SELECT'),
    ('schedules', 'ppa_schedules_insert_limit', 'INSERT'),
    ('schedules', 'ppa_schedules_update_limit', 'UPDATE'),
    ('schedules', 'ppa_schedules_delete_limit', 'DELETE'),
    ('notifications', 'ppa_notifications_read_limit', 'SELECT'),
    ('notifications', 'ppa_notifications_insert_limit', 'INSERT'),
    ('notifications', 'ppa_notifications_update_limit', 'UPDATE'),
    ('activity_attendance_records', 'ppa_activity_attendance_read_limit', 'SELECT'),
    ('tracking_audit_logs', 'ppa_tracking_audit_insert_limit', 'INSERT')
),
policy_checks AS (
  SELECT
    'restrictive access policy'::text AS check_type,
    format('public.%I: %s', r.table_name, r.policy_name) AS object_name,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = r.table_name
          AND policyname = r.policy_name
          AND cmd = r.command
          AND permissive = 'RESTRICTIVE'
      ) THEN 'OK'
      ELSE 'MISSING'
    END AS status,
    NULL::text AS actual_type
  FROM policy_requirements AS r
),
legacy_timestamp_check AS (
  SELECT
    'optional legacy column'::text AS check_type,
    'public.location_logs.recorded_at'::text AS object_name,
    CASE
      WHEN c.column_name IS NULL THEN 'NOT FOUND'
      ELSE 'AVAILABLE'
    END AS status,
    c.data_type::text AS actual_type
  FROM (VALUES (1)) AS one_row(n)
  LEFT JOIN information_schema.columns AS c
    ON c.table_schema = 'public'
   AND c.table_name = 'location_logs'
   AND c.column_name = 'recorded_at'
),
tracker_ingest_function_check AS (
  SELECT
    'device upload function'::text AS check_type,
    'public.ppa_record_tracker_location'::text AS object_name,
    CASE
      WHEN to_regprocedure(
        'public.ppa_record_tracker_location(text,text,double precision,double precision,double precision,double precision,integer)'
      ) IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
),
tracker_management_function_check AS (
  SELECT
    'tracker management function'::text AS check_type,
    'public.ppa_can_manage_tracker'::text AS object_name,
    CASE
      WHEN to_regprocedure('public.ppa_can_manage_tracker(text)') IS NULL
        THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
),
tracker_assignment_function_checks AS (
  SELECT
    'tracker assignment function'::text AS check_type,
    required.signature AS object_name,
    CASE
      WHEN to_regprocedure(required.signature) IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
  FROM (VALUES
    ('public.ppa_assign_tracker(text,text)'),
    ('public.ppa_unassign_tracker(text)')
  ) AS required(signature)
),
activity_attendance_function_checks AS (
  SELECT
    'activity attendance function'::text AS check_type,
    required.signature AS object_name,
    CASE
      WHEN to_regprocedure(required.signature) IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
  FROM (VALUES
    ('public.ppa_issue_activity_qr(text,boolean)'),
    ('public.ppa_record_activity_attendance(text,text,text)'),
    ('ppa_private.ppa_can_read_activity_attendance(text,text,text)')
  ) AS required(signature)
),
activity_qr_token_column_checks AS (
  SELECT
    'private activity QR ticket column'::text AS check_type,
    format('ppa_private.activity_qr_tokens.%I', required.column_name) AS object_name,
    CASE
      WHEN actual.column_name IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    actual.data_type::text AS actual_type
  FROM (VALUES
    ('token'),
    ('activity_id'),
    ('parolee_id'),
    ('officer_id'),
    ('parolee_name'),
    ('activity_title'),
    ('issued_at'),
    ('expires_at'),
    ('used_at')
  ) AS required(column_name)
  LEFT JOIN information_schema.columns AS actual
    ON actual.table_schema = 'ppa_private'
   AND actual.table_name = 'activity_qr_tokens'
   AND actual.column_name = required.column_name
),
activity_qr_token_privacy_check AS (
  SELECT
    'private activity QR tickets'::text AS check_type,
    'ppa_private.activity_qr_tokens'::text AS object_name,
    CASE
      WHEN c.oid IS NULL THEN 'MISSING'
      WHEN c.relrowsecurity
        AND NOT has_table_privilege('anon', c.oid, 'SELECT')
        AND NOT has_table_privilege('authenticated', c.oid, 'SELECT')
        THEN 'PRIVATE'
      ELSE 'CHECK PRIVILEGES'
    END AS status,
    NULL::text AS actual_type
  FROM pg_class AS c
  WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'ppa_private')
    AND c.relname = 'activity_qr_tokens'
    AND c.relkind IN ('r', 'p')
),
missing_activity_qr_token_check AS (
  SELECT
    'private activity QR tickets'::text AS check_type,
    'ppa_private.activity_qr_tokens'::text AS object_name,
    'MISSING'::text AS status,
    NULL::text AS actual_type
  WHERE to_regclass('ppa_private.activity_qr_tokens') IS NULL
),
schedule_notification_function_checks AS (
  SELECT
    'access helper'::text AS check_type,
    required.signature AS object_name,
    CASE
      WHEN to_regprocedure(required.signature) IS NULL THEN 'MISSING'
      ELSE 'OK'
    END AS status,
    NULL::text AS actual_type
  FROM (VALUES
    ('ppa_private.ppa_can_read_schedule(text,text)'),
    ('ppa_private.ppa_can_manage_schedule(text,text)'),
    ('ppa_private.ppa_can_read_notification(text)'),
    ('ppa_private.ppa_can_send_notification(text)')
  ) AS required(signature)
),
credential_access_check AS (
  SELECT
    'device credential access'::text AS check_type,
    'public.gps_tracker_credentials'::text AS object_name,
    CASE
      WHEN c.oid IS NULL THEN 'TABLE MISSING'
      WHEN c.relrowsecurity
        AND NOT has_table_privilege('anon', c.oid, 'SELECT')
        AND NOT has_table_privilege('authenticated', c.oid, 'SELECT')
        THEN 'PRIVATE'
      ELSE 'CHECK PRIVILEGES'
    END AS status,
    NULL::text AS actual_type
  FROM pg_class AS c
  WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    AND c.relname = 'gps_tracker_credentials'
    AND c.relkind IN ('r', 'p')
),
missing_credential_table_check AS (
  SELECT
    'device credential access'::text AS check_type,
    'public.gps_tracker_credentials'::text AS object_name,
    'TABLE MISSING'::text AS status,
    NULL::text AS actual_type
  WHERE to_regclass('public.gps_tracker_credentials') IS NULL
)
SELECT check_type, object_name, status, actual_type
FROM (
  SELECT * FROM table_checks
  UNION ALL
  SELECT * FROM column_checks
  UNION ALL
  SELECT * FROM rls_checks
  UNION ALL
  SELECT * FROM primary_key_checks
  UNION ALL
  SELECT * FROM realtime_checks
  UNION ALL
  SELECT * FROM policy_checks
  UNION ALL
  SELECT * FROM legacy_timestamp_check
  UNION ALL
  SELECT * FROM tracker_ingest_function_check
  UNION ALL
  SELECT * FROM tracker_management_function_check
  UNION ALL
  SELECT * FROM tracker_assignment_function_checks
  UNION ALL
  SELECT * FROM activity_attendance_function_checks
  UNION ALL
  SELECT * FROM activity_qr_token_column_checks
  UNION ALL
  SELECT * FROM activity_qr_token_privacy_check
  UNION ALL
  SELECT * FROM missing_activity_qr_token_check
  UNION ALL
  SELECT * FROM schedule_notification_function_checks
  UNION ALL
  SELECT * FROM credential_access_check
  UNION ALL
  SELECT * FROM missing_credential_table_check
) AS checks
ORDER BY check_type, object_name;
