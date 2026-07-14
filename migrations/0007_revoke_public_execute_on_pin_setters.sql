-- ============================================================================
-- 0007_revoke_public_execute_on_pin_setters.sql
--
-- APPLIED to production 2026-07-14, during go-live, before the app shipped.
--
-- THE BUG: Postgres grants EXECUTE to PUBLIC by default when a function is
-- created. `REVOKE ... FROM anon` does NOT remove that, because anon inherits
-- through PUBLIC. 0005 revoked anon on the two PIN setters but never revoked
-- PUBLIC, so anon could still reach:
--
--     POST /rest/v1/rpc/set_trainer_pin
--     POST /rest/v1/rpc/set_admin_pin
--
-- Caught by the Supabase security linter immediately after the go-live
-- migrations, while the old app was still deployed. I had asserted these were
-- revoked; they were not. Verify, do not assume.
--
-- NOT exploitable: both functions check
--     app_is_admin() OR app_is_service_role()
-- and return 'forbidden' otherwise. So the door was locked, but the corridor
-- leading to it was open. That is one layer of defence where there should be
-- two. This restores the second.
--
-- The login RPCs (sign_in, sign_in_front_desk, sign_in_kiosk, verify_*_pin) are
-- DELIBERATELY anon-callable and stay that way. You cannot sign in without
-- being able to call sign-in. They are re-granted explicitly below so the
-- intent is on the record rather than inherited by accident.
--
-- Idempotent.
-- ============================================================================

BEGIN;

REVOKE ALL ON FUNCTION set_trainer_pin(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION set_admin_pin(text, text)   FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_trainer_pin(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION set_admin_pin(text, text)   TO authenticated, service_role;

REVOKE ALL ON FUNCTION sign_in(uuid, text)            FROM PUBLIC;
REVOKE ALL ON FUNCTION sign_in_front_desk(text)       FROM PUBLIC;
REVOKE ALL ON FUNCTION sign_in_kiosk()                FROM PUBLIC;
REVOKE ALL ON FUNCTION verify_trainer_pin(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION verify_admin_pin(text)         FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sign_in(uuid, text)            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION sign_in_front_desk(text)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION sign_in_kiosk()                TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_trainer_pin(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_admin_pin(text)         TO anon, authenticated;

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.set_trainer_pin(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon can still execute set_trainer_pin.';
  END IF;
  IF has_function_privilege('anon', 'public.set_admin_pin(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon can still execute set_admin_pin.';
  END IF;
  IF NOT has_function_privilege('anon', 'public.sign_in(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon cannot execute sign_in - nobody could log in.';
  END IF;
  RAISE NOTICE 'grant self-test passed.';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
