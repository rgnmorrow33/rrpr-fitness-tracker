-- ============================================================================
-- 0008_lock_trainer_directory_to_select_only.sql
--
-- APPLIED to production 2026-07-14, ~2 hours after the v4.46 go-live.
--
-- THE BUG: trainer_directory was WRITABLE by anon. Live privilege escalation on
-- production. This was the most serious defect of the entire pass, and it was
-- introduced BY the pass.
--
-- HOW IT HAPPENED
--
-- Supabase ships DEFAULT PRIVILEGES that grant ALL on newly-created objects in
-- `public` to anon and authenticated. 0005 ran, in this order:
--
--     2. REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;   <- step 2
--     3. CREATE VIEW trainer_directory ...                       <- step 3
--
-- The view was born AFTER the revoke, so it picked up the default grants:
-- anon received INSERT, UPDATE, DELETE and TRUNCATE on it. The revoke could not
-- revoke privileges on an object that did not exist yet.
--
-- WHY THAT IS SEVERE
--
-- trainer_directory is a SECURITY DEFINER view (security_invoker off, by design,
-- so the login screen can read team names before anyone holds a token). It is
-- also auto-updatable. A write through it therefore executes as the view OWNER
-- and BYPASSES RLS on `trainers` completely.
--
-- Verified exploitable against production before this fix:
--
--     anon UPDATEs trainers via the view ... 1 row
--     anon INSERTs a trainer via the view .. 1 row
--     anon DELETEs a trainer via the view .. blocked only by an incidental FK
--                                            (notifications_target_trainer_id_fkey)
--
-- Anyone on the internet could insert, rename or modify team members. The delete
-- failed only because the trainer picked happened to have notifications rows; a
-- trainer without them would have deleted cleanly.
--
-- Impact assessment: the roster was writable for roughly two hours. Checked
-- afterwards - 21 trainers, 3 admins, zero rows created or updated in the window,
-- no suspicious names. Nobody found it.
--
-- THE LESSON (the same one, a fourth time)
--
-- The read path was correct all along. The GRANTS were not. A policy audit says
-- nothing about privileges, and `REVOKE ... FROM anon` cannot cover an object
-- created later. This was found only by enumerating
-- information_schema.role_table_grants and asking "why is that number 7?" -
-- after everything had already been declared done and shipped.
--
-- Idempotent.
-- ============================================================================

BEGIN;

REVOKE ALL ON trainer_directory FROM anon, authenticated, PUBLIC;
GRANT SELECT ON trainer_directory TO anon, authenticated;

-- Stop the same thing happening to the NEXT object created in public. Without
-- this, any future CREATE TABLE / CREATE VIEW hands anon full access again.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public' AND table_name = 'trainer_directory'
    AND grantee IN ('anon','authenticated')
    AND privilege_type <> 'SELECT';
  IF n > 0 THEN
    RAISE EXCEPTION 'ABORT: trainer_directory still has % non-SELECT grants.', n;
  END IF;

  IF NOT has_table_privilege('anon', 'public.trainer_directory', 'SELECT') THEN
    RAISE EXCEPTION 'ABORT: anon lost SELECT on trainer_directory - the login screen would go blank.';
  END IF;

  RAISE NOTICE 'trainer_directory is now SELECT-only for anon and authenticated.';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================================
-- STANDING CHECK. Run this after ANY migration that creates a table or view.
-- anon should have exactly ONE privilege in the entire public schema.
--
--   select table_name, privilege_type
--   from information_schema.role_table_grants
--   where grantee = 'anon' and table_schema = 'public';
--
--   -> expected, and ONLY this:  trainer_directory | SELECT
-- ============================================================================
