-- Creates the schedules and notifications tables used by the Flutter app.
-- Safe to re-run: creates missing tables, indexes and policies without dropping
-- existing rows. Review before running against a production Supabase project.
--
-- Prerequisite: public.profiles must contain id, role, officer_id, and
-- is_active. Run setup_profiles.sql first if the profile columns are missing.

DO $$
DECLARE
  missing_columns text;
BEGIN
  IF to_regclass('public.schedules') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = to_regclass('public.schedules')
        AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
    ) THEN
      RAISE EXCEPTION
        'Existing public.schedules must have id as its primary key for Supabase Realtime. Review and migrate it manually before running this script.';
    END IF;

    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
    FROM (VALUES
      ('id'),
      ('parolee_id'),
      ('parolee_name'),
      ('officer_id'),
      ('scheduled_at'),
      ('location'),
      ('type'),
      ('notes'),
      ('created_at')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'public'
        AND actual.table_name = 'schedules'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.schedules has an incompatible schema; missing columns: %. Review and migrate that table manually before running this script.',
        missing_columns;
    END IF;
  END IF;

  IF to_regclass('public.notifications') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = to_regclass('public.notifications')
        AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
    ) THEN
      RAISE EXCEPTION
        'Existing public.notifications must have id as its primary key for Supabase Realtime. Review and migrate it manually before running this script.';
    END IF;

    SELECT string_agg(required.column_name, ', ')
    INTO missing_columns
    FROM (VALUES
      ('id'),
      ('user_id'),
      ('title'),
      ('body'),
      ('type'),
      ('created_at'),
      ('read')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS actual
      WHERE actual.table_schema = 'public'
        AND actual.table_name = 'notifications'
        AND actual.column_name = required.column_name
    );

    IF missing_columns IS NOT NULL THEN
      RAISE EXCEPTION
        'Existing public.notifications has an incompatible schema; missing columns: %. Review and migrate that table manually before running this script.',
        missing_columns;
    END IF;
  END IF;

  SELECT string_agg(required.column_name, ', ')
  INTO missing_columns
  FROM (VALUES
    ('id'),
    ('role'),
    ('officer_id'),
    ('is_active')
  ) AS required(column_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns AS actual
    WHERE actual.table_schema = 'public'
      AND actual.table_name = 'profiles'
      AND actual.column_name = required.column_name
  );

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'Schedule/notification setup stopped: public.profiles is missing required columns: %',
      missing_columns;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parolee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  parolee_name text NOT NULL,
  officer_id text NOT NULL,
  scheduled_at timestamptz NOT NULL,
  location text NOT NULL DEFAULT '',
  type text NOT NULL DEFAULT 'Check-in',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text NOT NULL,
  type text NOT NULL CHECK (type IN ('alert', 'success', 'reminder', 'info')),
  created_at timestamptz NOT NULL DEFAULT now(),
  read boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS schedules_officer_scheduled_at_idx
  ON public.schedules (officer_id, scheduled_at);
CREATE INDEX IF NOT EXISTS schedules_parolee_scheduled_at_idx
  ON public.schedules (parolee_id, scheduled_at);
CREATE INDEX IF NOT EXISTS notifications_user_created_at_idx
  ON public.notifications (user_id, created_at DESC);

ALTER TABLE public.schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Keep RLS helper functions outside the API-exposed public schema.
CREATE SCHEMA IF NOT EXISTS ppa_private;
REVOKE ALL ON SCHEMA ppa_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA ppa_private TO authenticated;

CREATE OR REPLACE FUNCTION ppa_private.ppa_can_read_schedule(
  target_parolee_id text,
  target_officer_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(EXISTS (
    SELECT 1
    FROM public.profiles AS actor
    JOIN public.profiles AS parolee
      ON parolee.id::text = target_parolee_id
    WHERE actor.id::text = auth.uid()::text
      AND coalesce(actor.is_active, false)
      AND coalesce(parolee.is_active, false)
      AND lower(parolee.role::text) = 'parolee'
      AND (
        lower(actor.role::text) = 'admin'
        OR (
          lower(actor.role::text) = 'parolee'
          AND actor.id::text = parolee.id::text
          AND target_officer_id IS NOT DISTINCT FROM parolee.officer_id
        )
        OR (
          lower(actor.role::text) = 'officer'
          AND actor.id::text = target_officer_id
          AND parolee.officer_id = actor.id::text
        )
      )
  ), false)
$$;

CREATE OR REPLACE FUNCTION ppa_private.ppa_can_manage_schedule(
  target_parolee_id text,
  target_officer_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(EXISTS (
    SELECT 1
    FROM public.profiles AS actor
    JOIN public.profiles AS parolee
      ON parolee.id::text = target_parolee_id
    WHERE actor.id::text = auth.uid()::text
      AND coalesce(actor.is_active, false)
      AND coalesce(parolee.is_active, false)
      AND lower(parolee.role::text) = 'parolee'
      AND parolee.officer_id = target_officer_id
      AND (
        lower(actor.role::text) = 'admin'
        OR (
          lower(actor.role::text) = 'officer'
          AND actor.id::text = target_officer_id
        )
      )
  ), false)
$$;

CREATE OR REPLACE FUNCTION ppa_private.ppa_can_read_notification(target_user_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(EXISTS (
    SELECT 1
    FROM public.profiles AS actor
    WHERE actor.id::text = auth.uid()::text
      AND actor.id::text = target_user_id
      AND coalesce(actor.is_active, false)
  ), false)
$$;

CREATE OR REPLACE FUNCTION ppa_private.ppa_can_send_notification(target_user_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(EXISTS (
    SELECT 1
    FROM public.profiles AS sender
    JOIN public.profiles AS recipient
      ON recipient.id::text = target_user_id
    WHERE sender.id::text = auth.uid()::text
      AND coalesce(sender.is_active, false)
      AND coalesce(recipient.is_active, false)
      AND (
        lower(sender.role::text) = 'admin'
        OR sender.id::text = recipient.id::text
        OR (
          lower(sender.role::text) = 'officer'
          AND lower(recipient.role::text) = 'parolee'
          AND recipient.officer_id = sender.id::text
        )
        OR (
          lower(sender.role::text) = 'parolee'
          AND lower(recipient.role::text) = 'officer'
          AND sender.officer_id = recipient.id::text
        )
      )
  ), false)
$$;

REVOKE ALL ON FUNCTION ppa_private.ppa_can_read_schedule(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ppa_private.ppa_can_manage_schedule(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ppa_private.ppa_can_read_notification(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ppa_private.ppa_can_send_notification(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ppa_private.ppa_can_read_schedule(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ppa_private.ppa_can_manage_schedule(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION ppa_private.ppa_can_read_notification(text) TO authenticated;
GRANT EXECUTE ON FUNCTION ppa_private.ppa_can_send_notification(text) TO authenticated;

REVOKE ALL ON TABLE public.schedules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.notifications FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.schedules TO authenticated;
GRANT SELECT ON TABLE public.notifications TO authenticated;
GRANT INSERT (id, user_id, title, body, type, created_at, read)
  ON TABLE public.notifications TO authenticated;
GRANT UPDATE (read) ON TABLE public.notifications TO authenticated;

DROP POLICY IF EXISTS ppa_schedules_read ON public.schedules;
DROP POLICY IF EXISTS ppa_schedules_read_limit ON public.schedules;
CREATE POLICY ppa_schedules_read ON public.schedules
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (ppa_private.ppa_can_read_schedule(parolee_id::text, officer_id::text));
CREATE POLICY ppa_schedules_read_limit ON public.schedules
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (ppa_private.ppa_can_read_schedule(parolee_id::text, officer_id::text));

DROP POLICY IF EXISTS ppa_schedules_insert ON public.schedules;
DROP POLICY IF EXISTS ppa_schedules_insert_limit ON public.schedules;
CREATE POLICY ppa_schedules_insert ON public.schedules
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));
CREATE POLICY ppa_schedules_insert_limit ON public.schedules
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));

DROP POLICY IF EXISTS ppa_schedules_update ON public.schedules;
DROP POLICY IF EXISTS ppa_schedules_update_limit ON public.schedules;
CREATE POLICY ppa_schedules_update ON public.schedules
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text))
  WITH CHECK (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));
CREATE POLICY ppa_schedules_update_limit ON public.schedules
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text))
  WITH CHECK (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));

DROP POLICY IF EXISTS ppa_schedules_delete ON public.schedules;
DROP POLICY IF EXISTS ppa_schedules_delete_limit ON public.schedules;
CREATE POLICY ppa_schedules_delete ON public.schedules
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));
CREATE POLICY ppa_schedules_delete_limit ON public.schedules
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (ppa_private.ppa_can_manage_schedule(parolee_id::text, officer_id::text));

DROP POLICY IF EXISTS ppa_notifications_read ON public.notifications;
DROP POLICY IF EXISTS ppa_notifications_read_limit ON public.notifications;
CREATE POLICY ppa_notifications_read ON public.notifications
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (ppa_private.ppa_can_read_notification(user_id::text));
CREATE POLICY ppa_notifications_read_limit ON public.notifications
  AS RESTRICTIVE FOR SELECT TO authenticated
  USING (ppa_private.ppa_can_read_notification(user_id::text));

DROP POLICY IF EXISTS ppa_notifications_insert ON public.notifications;
DROP POLICY IF EXISTS ppa_notifications_insert_limit ON public.notifications;
CREATE POLICY ppa_notifications_insert ON public.notifications
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    read = false
    AND ppa_private.ppa_can_send_notification(user_id::text)
  );
CREATE POLICY ppa_notifications_insert_limit ON public.notifications
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (
    read = false
    AND ppa_private.ppa_can_send_notification(user_id::text)
  );

DROP POLICY IF EXISTS ppa_notifications_update ON public.notifications;
DROP POLICY IF EXISTS ppa_notifications_update_limit ON public.notifications;
CREATE POLICY ppa_notifications_update ON public.notifications
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (ppa_private.ppa_can_read_notification(user_id::text))
  WITH CHECK (ppa_private.ppa_can_read_notification(user_id::text));
CREATE POLICY ppa_notifications_update_limit ON public.notifications
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (ppa_private.ppa_can_read_notification(user_id::text))
  WITH CHECK (ppa_private.ppa_can_read_notification(user_id::text));

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'schedules'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.schedules';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'notifications'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
