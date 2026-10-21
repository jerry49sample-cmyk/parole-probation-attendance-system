-- Run only if verify_schema.sql reports the listed profiles columns missing.
-- Adds the profile fields used by the app and access policies without dropping
-- or replacing existing columns or records.
-- Existing profiles receive is_active = true, matching the app's default for
-- profiles that do not yet have an active flag.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS officer_id text,
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS avatar_initials text,
  ADD COLUMN IF NOT EXISTS case_number text,
  ADD COLUMN IF NOT EXISTS department text,
  ADD COLUMN IF NOT EXISTS supervision_start_date date,
  ADD COLUMN IF NOT EXISTS supervision_end_date date,
  ADD COLUMN IF NOT EXISTS supervision_is_suspended boolean NOT NULL DEFAULT false;

-- Preserve officer assignments if this project previously used the legacy name.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'profiles'
      AND column_name = 'assigned_officer_id'
  ) THEN
    EXECUTE '
      UPDATE public.profiles
      SET officer_id = assigned_officer_id::text
      WHERE officer_id IS NULL
        AND assigned_officer_id IS NOT NULL
    ';
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
