-- Adds the Flutter activity-attendance tables and server-validated QR RPCs.
-- Additive and safe to re-run; do not run against production without reviewing
-- the schema and access rules first.
--
-- Prerequisites: public.profiles and public.activities must already exist with
-- the base columns checked below. Missing activity assignment and status
-- columns are added with non-destructive defaults. No existing attendance
-- rows are deleted or rewritten.

CREATE SCHEMA IF NOT EXISTS ppa_private;
REVOKE CREATE ON SCHEMA ppa_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA ppa_private TO authenticated;

DO $$
DECLARE
  missing_columns text;
  id_type text;
BEGIN
  SELECT string_agg(required.table_name || '.' || required.column_name, ', ')
  INTO missing_columns
  FROM (VALUES
    ('profiles', 'id'),
    ('profiles', 'role'),
    ('profiles', 'is_active'),
    ('profiles', 'full_name'),
    ('activities', 'id'),
    ('activities', 'title')
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
      'Activity attendance setup stopped; required columns are missing: %',
      missing_columns;
  END IF;

  IF to_regclass('public.activity_attendance_records') IS NOT NULL THEN
    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
    FROM (VALUES
      ('id'),
      ('activity_id'),
      ('parolee_id'),
      ('parolee_name'),
      ('officer_id'),
      ('status'),
      ('scanned_at'),
      ('verified_by_officer'),
      ('ticket_timestamp'),
      ('activity_title')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'public'
        AND actual.table_name = 'activity_attendance_records'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.activity_attendance_records is incompatible; missing columns: %',
        missing_columns;
    END IF;

    SELECT data_type
    INTO id_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'activity_attendance_records'
      AND column_name = 'id';

    IF id_type <> 'uuid' THEN
      RAISE EXCEPTION
        'Existing public.activity_attendance_records.id must be uuid; review its schema before running this script.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'activity_attendance_records'
        AND column_name IN ('activity_id', 'parolee_id', 'officer_id', 'status')
        AND data_type <> 'text'
    ) THEN
      RAISE EXCEPTION
        'Existing public.activity_attendance_records activity_id, parolee_id, officer_id, and status columns must be text.';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = to_regclass('public.activity_attendance_records')
        AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
    ) THEN
      RAISE EXCEPTION
        'Existing public.activity_attendance_records must have PRIMARY KEY (id). Review its schema before running this script.';
    END IF;
  END IF;

  IF to_regclass('ppa_private.activity_qr_tokens') IS NOT NULL THEN
    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
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
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'ppa_private'
        AND actual.table_name = 'activity_qr_tokens'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing ppa_private.activity_qr_tokens is incompatible; missing columns: %',
        missing_columns;
    END IF;
  END IF;
END
$$;

ALTER TABLE public.activities
  ADD COLUMN IF NOT EXISTS assigned_officer_id text,
  ADD COLUMN IF NOT EXISTS assigned_parolee_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';

CREATE TABLE IF NOT EXISTS public.activity_attendance_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id text NOT NULL,
  parolee_id text NOT NULL,
  parolee_name text NOT NULL,
  officer_id text NOT NULL,
  status text NOT NULL CHECK (status IN ('present', 'absent', 'late', 'pending')),
  scanned_at timestamptz NOT NULL DEFAULT now(),
  verified_by_officer boolean NOT NULL DEFAULT true,
  ticket_timestamp timestamptz NOT NULL,
  activity_title text
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.activity_attendance_records
    GROUP BY activity_id, parolee_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Activity attendance has duplicate activity_id/parolee_id rows. Resolve duplicates before adding the required unique index.';
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS activity_attendance_records_activity_parolee_uidx
  ON public.activity_attendance_records (activity_id, parolee_id);
CREATE INDEX IF NOT EXISTS activity_attendance_records_activity_scanned_idx
  ON public.activity_attendance_records (activity_id, scanned_at DESC);
CREATE INDEX IF NOT EXISTS activity_attendance_records_parolee_scanned_idx
  ON public.activity_attendance_records (parolee_id, scanned_at DESC);

CREATE TABLE IF NOT EXISTS ppa_private.activity_qr_tokens (
  token text PRIMARY KEY,
  activity_id text NOT NULL,
  parolee_id text NOT NULL,
  officer_id text NOT NULL,
  parolee_name text NOT NULL,
  activity_title text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);

CREATE INDEX IF NOT EXISTS activity_qr_tokens_assignment_idx
  ON ppa_private.activity_qr_tokens (activity_id, parolee_id, issued_at DESC);

ALTER TABLE public.activity_attendance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE ppa_private.activity_qr_tokens ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.activity_attendance_records FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.activity_attendance_records TO authenticated;
REVOKE ALL ON TABLE ppa_private.activity_qr_tokens FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION ppa_private.ppa_can_read_activity_attendance(
  target_activity_id text,
  target_parolee_id text,
  target_officer_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, ppa_private, pg_temp
AS $$
  SELECT coalesce(EXISTS (
    SELECT 1
    FROM public.activities AS activity
    JOIN public.profiles AS actor
      ON actor.id::text = auth.uid()::text
    JOIN public.profiles AS parolee
      ON parolee.id::text = target_parolee_id
    WHERE activity.id::text = target_activity_id
      AND activity.assigned_officer_id::text = target_officer_id
      AND coalesce(to_jsonb(activity.assigned_parolee_ids) ? target_parolee_id, false)
      AND coalesce(actor.is_active, false)
      AND coalesce(parolee.is_active, false)
      AND lower(parolee.role::text) = 'parolee'
      AND (
        lower(actor.role::text) = 'admin'
        OR (
          lower(actor.role::text) = 'officer'
          AND actor.id::text = target_officer_id
        )
        OR (
          lower(actor.role::text) = 'parolee'
          AND actor.id::text = target_parolee_id
        )
      )
  ), false)
$$;

REVOKE ALL ON FUNCTION ppa_private.ppa_can_read_activity_attendance(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ppa_private.ppa_can_read_activity_attendance(text, text, text)
  TO authenticated;

DROP POLICY IF EXISTS ppa_activity_attendance_read
  ON public.activity_attendance_records;
DROP POLICY IF EXISTS ppa_activity_attendance_read_limit
  ON public.activity_attendance_records;
CREATE POLICY ppa_activity_attendance_read
  ON public.activity_attendance_records
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    ppa_private.ppa_can_read_activity_attendance(
      activity_id,
      parolee_id,
      officer_id
    )
  );
CREATE POLICY ppa_activity_attendance_read_limit
  ON public.activity_attendance_records
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (
    ppa_private.ppa_can_read_activity_attendance(
      activity_id,
      parolee_id,
      officer_id
    )
  );

CREATE OR REPLACE FUNCTION public.ppa_issue_activity_qr(
  p_activity_id text,
  p_rotate boolean DEFAULT false
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
  v_ticket ppa_private.activity_qr_tokens%ROWTYPE;
  v_officer_exists boolean;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sign in before requesting an activity QR code';
  END IF;

  SELECT lower(profile.role::text), coalesce(profile.is_active, false), profile.full_name
  INTO v_role, v_is_active, v_parolee_name
  FROM public.profiles AS profile
  WHERE profile.id::text = v_user_id;

  IF v_role <> 'parolee' OR NOT coalesce(v_is_active, false) THEN
    RAISE EXCEPTION 'Only an active parolee can request an activity QR code';
  END IF;

  IF p_activity_id IS NULL OR length(trim(p_activity_id)) = 0 THEN
    RAISE EXCEPTION 'Activity is required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_user_id), hashtext(p_activity_id));

  SELECT activity.*
  INTO v_activity
  FROM public.activities AS activity
  WHERE activity.id::text = p_activity_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity not found';
  END IF;
  IF NOT coalesce(to_jsonb(v_activity.assigned_parolee_ids) ? v_user_id, false) THEN
    RAISE EXCEPTION 'You are not assigned to this activity';
  END IF;
  IF lower(coalesce(v_activity.status::text, '')) IN ('missed', 'completed') THEN
    RAISE EXCEPTION 'This activity is no longer available for check-in';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS officer
    WHERE officer.id::text = v_activity.assigned_officer_id::text
      AND lower(officer.role::text) = 'officer'
      AND coalesce(officer.is_active, false)
  )
  INTO v_officer_exists;

  IF NOT coalesce(v_officer_exists, false) THEN
    RAISE EXCEPTION 'No active supervising officer is linked to this activity';
  END IF;

  IF coalesce(p_rotate, false) THEN
    UPDATE ppa_private.activity_qr_tokens
    SET used_at = now()
    WHERE activity_id = p_activity_id
      AND parolee_id = v_user_id
      AND used_at IS NULL;
  ELSE
    SELECT ticket.*
    INTO v_ticket
    FROM ppa_private.activity_qr_tokens AS ticket
    WHERE ticket.activity_id = p_activity_id
      AND ticket.parolee_id = v_user_id
      AND ticket.used_at IS NULL
      AND ticket.expires_at > now()
    ORDER BY ticket.issued_at DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'token', v_ticket.token,
        'activity_id', v_ticket.activity_id,
        'parolee_id', v_ticket.parolee_id,
        'officer_id', v_ticket.officer_id,
        'parolee_name', v_ticket.parolee_name,
        'activity_title', v_ticket.activity_title,
        'issued_at', v_ticket.issued_at
      );
    END IF;
  END IF;

  INSERT INTO ppa_private.activity_qr_tokens (
    token,
    activity_id,
    parolee_id,
    officer_id,
    parolee_name,
    activity_title,
    issued_at,
    expires_at
  )
  VALUES (
    gen_random_uuid()::text,
    p_activity_id,
    v_user_id,
    v_activity.assigned_officer_id::text,
    coalesce(nullif(trim(v_parolee_name), ''), 'Parolee'),
    v_activity.title::text,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING * INTO v_ticket;

  RETURN jsonb_build_object(
    'token', v_ticket.token,
    'activity_id', v_ticket.activity_id,
    'parolee_id', v_ticket.parolee_id,
    'officer_id', v_ticket.officer_id,
    'parolee_name', v_ticket.parolee_name,
    'activity_title', v_ticket.activity_title,
    'issued_at', v_ticket.issued_at
  );
END
$$;

CREATE OR REPLACE FUNCTION public.ppa_record_activity_attendance(
  p_token text,
  p_activity_id text,
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
  v_activity public.activities%ROWTYPE;
  v_ticket ppa_private.activity_qr_tokens%ROWTYPE;
  v_existing public.activity_attendance_records%ROWTYPE;
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
    RAISE EXCEPTION 'Only an active officer can record activity attendance';
  END IF;
  IF v_status NOT IN ('present', 'absent', 'late') THEN
    RAISE EXCEPTION 'Invalid activity attendance status';
  END IF;
  IF p_token IS NULL OR length(p_token) > 200
    OR p_activity_id IS NULL OR length(trim(p_activity_id)) = 0
  THEN
    RAISE EXCEPTION 'Invalid or expired activity QR code';
  END IF;

  SELECT activity.*
  INTO v_activity
  FROM public.activities AS activity
  WHERE activity.id::text = p_activity_id
  FOR UPDATE;

  IF NOT FOUND
    OR v_activity.assigned_officer_id::text <> v_user_id
    OR lower(coalesce(v_activity.status::text, '')) IN ('missed', 'completed')
  THEN
    RAISE EXCEPTION 'This activity is not assigned to you or is no longer available';
  END IF;

  SELECT ticket.*
  INTO v_ticket
  FROM ppa_private.activity_qr_tokens AS ticket
  WHERE ticket.token = p_token
  FOR UPDATE;

  IF NOT FOUND
    OR v_ticket.activity_id <> p_activity_id
    OR v_ticket.officer_id <> v_user_id
    OR v_ticket.used_at IS NOT NULL
    OR v_ticket.expires_at <= now()
    OR NOT coalesce(
      to_jsonb(v_activity.assigned_parolee_ids) ? v_ticket.parolee_id,
      false
    )
  THEN
    RAISE EXCEPTION 'This QR code is not valid for an activity assigned to you';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles AS parolee
    WHERE parolee.id::text = v_ticket.parolee_id
      AND lower(parolee.role::text) = 'parolee'
      AND coalesce(parolee.is_active, false)
  ) THEN
    RAISE EXCEPTION 'The assigned parolee account is not active';
  END IF;

  SELECT attendance.*
  INTO v_existing
  FROM public.activity_attendance_records AS attendance
  WHERE attendance.activity_id = p_activity_id
    AND attendance.parolee_id = v_ticket.parolee_id
  FOR UPDATE;

  IF FOUND
    AND lower(v_existing.status) IN ('present', 'late')
    AND v_status IN ('present', 'late')
  THEN
    RAISE EXCEPTION '% is already marked %',
      v_ticket.parolee_name,
      initcap(v_existing.status);
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
    v_ticket.parolee_id,
    v_ticket.parolee_name,
    v_user_id,
    v_status,
    now(),
    true,
    v_ticket.issued_at,
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

  UPDATE ppa_private.activity_qr_tokens
  SET used_at = now()
  WHERE token = p_token;

  RETURN to_jsonb(v_record);
END
$$;

REVOKE ALL ON FUNCTION public.ppa_issue_activity_qr(text, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ppa_record_activity_attendance(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_issue_activity_qr(text, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.ppa_record_activity_attendance(text, text, text)
  TO authenticated;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'activity_attendance_records'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.activity_attendance_records';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
