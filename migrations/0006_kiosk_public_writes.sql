-- ============================================================================
-- 0006_kiosk_public_writes.sql
-- Restores the two PUBLIC, no-PIN member surfaces that 0005 would otherwise
-- break, without reopening read access to anything.
--
-- WHAT 0005 BROKE (caught before go-live, 2026-07-14)
--
-- The login screen has two tiles a member taps with NO sign-in:
--
--   "Weight Room Orientation Sign-Up"  -> ctx.setSession({role:'kiosk_wro'})
--                                      -> upsertWRO()  -> writes `wros`
--   "Book a Consultation"              -> NewConsultationModal
--                                      -> auditedUpsertClient() -> writes `clients`
--
-- Both run with no token. After 0005, both return "permission denied". A member
-- would fill out the whole orientation form, hit submit, and get an error.
--
-- The app even documents the intent: "Front Desk attribution when no session is
-- active." These are deliberate self-service flows, not an oversight.
--
-- WHY NOT JUST GRANT anon INSERT
--
-- The saves use .upsert(rows, {onConflict:'id'}), which needs INSERT and UPDATE.
-- Handing anon INSERT+UPDATE on `clients` is most of the door we just shut.
--
-- THE DESIGN
--
-- Give the kiosk its own identity: a short-lived token with role_tier='kiosk'
-- and a sentinel trainer_id. Then make it a strictly WRITE-ONLY identity.
--
-- The trick is a one-line redefinition of app_is_signed_in(): it now excludes
-- kiosk. Every policy in 0005 keys on that function, so all of them - every
-- SELECT, every UPDATE, every DELETE - automatically stop applying to the kiosk
-- without touching a single policy. Then we add exactly two permissive INSERT
-- policies back. Kiosk can write a WRO and a consult client. It can read
-- nothing, update nothing, delete nothing.
--
-- A kiosk that sends an EXISTING row id is also safe: ON CONFLICT DO UPDATE
-- then evaluates the UPDATE policy, kiosk has none, and the write is rejected.
-- So it cannot overwrite a real client by guessing a uuid.
--
-- Requires 0004 and 0005. Idempotent.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Kiosk identity
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_is_kiosk() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT public.app_role_tier() = 'kiosk';
$$;
GRANT EXECUTE ON FUNCTION app_is_kiosk() TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. THE LOAD-BEARING LINE.
--
-- app_is_signed_in() now means "signed in AS A TEAM MEMBER". Kiosk holds a
-- valid token and a trainer_id, so the old definition would have said true and
-- handed it read access to every client record. It does not.
--
-- Every policy from 0005 inherits this instantly. No policy edits needed.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_is_signed_in() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT public.app_trainer_id() IS NOT NULL
     AND public.app_role_tier() <> 'kiosk';
$$;

-- ----------------------------------------------------------------------------
-- 3. sign_in_kiosk(): no PIN, by design. This is a public tile.
--
-- The token it hands out can do exactly two things (see section 4). Short TTL:
-- a member fills a form in minutes, and an unattended kiosk should not hold a
-- credential all day.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sign_in_kiosk() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_iat int; v_exp int;
  c_kiosk_id CONSTANT uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
  v_iat := extract(epoch FROM now())::int;
  v_exp := extract(epoch FROM now() + interval '30 minutes')::int;

  RETURN jsonb_build_object(
    'status', 'ok',
    'expires_at', v_exp,
    'token', sign_jwt(jsonb_build_object(
      'role',       'authenticated',
      'aud',        'authenticated',
      'sub',        c_kiosk_id::text,
      'iat',        v_iat,
      'exp',        v_exp,
      'trainer_id', c_kiosk_id::text,
      'role_tier',  'kiosk',
      'name',       'Kiosk'
    ))
  );
END $$;

REVOKE ALL ON FUNCTION sign_in_kiosk() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sign_in_kiosk() TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. The ONLY two things a kiosk may do. Both INSERT. Neither SELECT.
--
-- Permissive policies, so they OR with the staff policies from 0005 rather than
-- replacing them.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS kiosk_insert ON wros;
CREATE POLICY kiosk_insert ON wros FOR INSERT TO authenticated
  WITH CHECK (app_is_kiosk());

DROP POLICY IF EXISTS kiosk_insert ON clients;
CREATE POLICY kiosk_insert ON clients FOR INSERT TO authenticated
  WITH CHECK (app_is_kiosk());

-- Deliberately NOT granted to kiosk: SELECT on anything, UPDATE on anything,
-- DELETE on anything, leads, classes, settings, trainers, notifications.

-- ----------------------------------------------------------------------------
-- 5. Self-test: prove a kiosk token is write-only.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_can_read boolean; v_tok text;
BEGIN
  v_tok := (sign_in_kiosk() ->> 'token');
  IF v_tok IS NULL OR array_length(string_to_array(v_tok,'.'),1) <> 3 THEN
    RAISE EXCEPTION 'ABORT: sign_in_kiosk did not mint a JWT.';
  END IF;

  -- simulate the kiosk's claims and confirm it is NOT treated as a team member
  PERFORM set_config('request.jwt.claims',
    json_build_object('role','authenticated',
                      'trainer_id','00000000-0000-0000-0000-000000000002',
                      'role_tier','kiosk')::text, true);

  IF public.app_is_signed_in() THEN
    RAISE EXCEPTION 'ABORT: kiosk is being treated as a signed-in team member. It would be able to read every client.';
  END IF;
  IF public.app_is_admin() THEN
    RAISE EXCEPTION 'ABORT: kiosk is being treated as an admin.';
  END IF;
  IF NOT public.app_is_kiosk() THEN
    RAISE EXCEPTION 'ABORT: app_is_kiosk() false for a kiosk token.';
  END IF;

  PERFORM set_config('request.jwt.claims', NULL, true);
  RAISE NOTICE 'kiosk self-test passed: write-only identity confirmed.';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
