-- ============================================================================
-- 0004_auth_identity.sql
-- Gives the DATABASE an identity to key policies on.
--
-- Pairs with 0005_rls_identity_policies.sql. Together these are "Deploy 2": the
-- pass that actually closes client data to the public internet. 0002 + 0003
-- ("Deploy 1") hash the PINs and lock the PIN tables but leave anon able to
-- read every client row. This is the fix for that.
--
-- STAGED. Verified end to end on a Supabase branch 2026-07-13. Do not apply to
-- production until the app-side token wiring ships. See RLS_GO_LIVE_RUNBOOK.md.
--
-- WHY NO EDGE FUNCTION: minting the JWT in Postgres means no Deno, no
-- `supabase functions deploy`, no second deploy target, and no function secret
-- to rotate. Everything stays in a migration, which matches how this repo works.
-- The signing is plain HS256 over pgcrypto's hmac(); it is what the (deprecated)
-- pgjwt extension does, without the dependency.
--
-- ---------------------------------------------------------------------------
-- PREREQUISITE, ONE TIME, PER PROJECT. THIS MIGRATION IS INERT WITHOUT IT.
--
--   1. Dashboard > Project Settings > API > JWT Secret. Copy it.
--   2. SQL editor:
--        select vault.create_secret('<paste the JWT secret>', 'app_jwt_secret');
--
-- PostgREST validates every incoming token against that same secret, which is
-- what makes a token we sign here a token PostgREST trusts. Get this wrong and
-- sign_in() raises rather than minting a bad token. Fail closed, by design.
-- ---------------------------------------------------------------------------
--
-- Idempotent. Safe to re-run.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- base64url (RFC 7515): standard base64, then +/ -> -_ and strip padding.
-- translate() deletes chars in `from` that have no counterpart in `to`, which
-- is how '=' and newlines disappear.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _b64url(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_temp AS $$
  SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;

-- ----------------------------------------------------------------------------
-- HS256 signer. SECURITY DEFINER so it can reach Vault. The secret is never
-- returned, logged, or exposed to the caller.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sign_jwt(payload jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_secret text; v_signing_input text;
BEGIN
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets WHERE name = 'app_jwt_secret';

  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'sign_jwt: vault secret "app_jwt_secret" is not set. See the 0004 header.';
  END IF;

  v_signing_input :=
       _b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'))
    || '.'
    || _b64url(convert_to(payload::text, 'utf8'));

  RETURN v_signing_input || '.' || _b64url(extensions.hmac(v_signing_input, v_secret, 'sha256'));
END $$;

-- Neither of these is callable by the app. Only sign_in() uses them.
REVOKE ALL ON FUNCTION _b64url(bytea) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION sign_jwt(jsonb) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- sign_in(): the single call the app makes at the PIN screen.
--
-- Delegates the PIN check to verify_trainer_pin() from 0002, so it inherits the
-- 5-failures-in-15-minutes lockout for free. On failure it returns the same
-- status strings the app already handles ('wrong' / 'locked' / 'unset'), so the
-- existing PinModal error handling keeps working unchanged.
--
-- On success it returns a 12-hour JWT. Twelve hours covers a full shift on a
-- shared iPad without a mid-session re-auth, and expires overnight so a kiosk
-- left open is not a standing credential.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sign_in(p_trainer_id uuid, p_pin text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_status text; v_name text; v_tier text; v_iat int; v_exp int;
BEGIN
  v_status := verify_trainer_pin(p_trainer_id, p_pin);
  IF v_status <> 'ok' THEN
    RETURN jsonb_build_object('status', v_status);
  END IF;

  SELECT name, COALESCE(role_tier, role, 'trainer') INTO v_name, v_tier
  FROM trainers WHERE id = p_trainer_id;

  v_iat := extract(epoch FROM now())::int;
  v_exp := extract(epoch FROM now() + interval '12 hours')::int;

  RETURN jsonb_build_object(
    'status',     'ok',
    'expires_at', v_exp,
    'trainer',    jsonb_build_object('id', p_trainer_id, 'name', v_name, 'role_tier', v_tier),
    'token', sign_jwt(jsonb_build_object(
      'role',       'authenticated',  -- makes PostgREST switch off the anon role
      'aud',        'authenticated',
      'sub',        p_trainer_id::text,
      'iat',        v_iat,
      'exp',        v_exp,
      'trainer_id', p_trainer_id::text,
      'role_tier',  v_tier,
      'name',       v_name
    ))
  );
END $$;

REVOKE ALL ON FUNCTION sign_in(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sign_in(uuid, text) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- Claim accessors. Every policy in 0005 keys on these.
-- Fail closed: no token -> NULL trainer_id -> app_is_signed_in() is false.
-- STABLE, so the planner evaluates them once per statement, not once per row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_trainer_id() RETURNS uuid
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb ->> 'trainer_id', '')::uuid;
$$;

CREATE OR REPLACE FUNCTION app_role_tier() RETURNS text
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT COALESCE(current_setting('request.jwt.claims', true)::jsonb ->> 'role_tier', '');
$$;

CREATE OR REPLACE FUNCTION app_is_admin() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT public.app_role_tier() = 'admin';
$$;

CREATE OR REPLACE FUNCTION app_is_signed_in() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT public.app_trainer_id() IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION app_trainer_id()   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION app_role_tier()    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION app_is_admin()     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION app_is_signed_in() TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- verify_jwt_secret(): PROVE the Vault secret is the RIGHT one.
--
-- This exists because of a real failure on 2026-07-13. The Vault secret was set
-- to a WRONG value (the placeholder text got pasted instead of the key). Nothing
-- errored. sign_jwt happily minted well-formed tokens. PostgREST rejected every
-- single one, because they were signed with a secret it does not know. The app
-- would have come up looking fine, the login would have "succeeded," and then
-- every screen would have been empty with no error anywhere. That is a brutal
-- thing to debug from the outside.
--
-- The trick: the project's own anon key IS a JWT signed with the project's JWT
-- secret. So re-sign the anon key's header.payload with whatever is in Vault and
-- compare against the anon key's real signature. Match means the secret is right.
--
-- HOW TO USE (do this immediately after vault.create_secret, every environment):
--     select verify_jwt_secret('<paste this project''s anon key>');
--   -> true  = correct secret, sign_in will produce tokens PostgREST accepts
--   -> false = WRONG secret. Fix it before going further. Nothing else will work.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verify_jwt_secret(p_reference_jwt text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_secret text; v_input text; v_sig text;
BEGIN
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets WHERE name = 'app_jwt_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'verify_jwt_secret: vault secret "app_jwt_secret" is not set.';
  END IF;

  IF array_length(string_to_array(p_reference_jwt, '.'), 1) <> 3 THEN
    RAISE EXCEPTION 'verify_jwt_secret: that is not a JWT. Pass this project''s anon key.';
  END IF;

  v_input := split_part(p_reference_jwt,'.',1) || '.' || split_part(p_reference_jwt,'.',2);
  v_sig   := split_part(p_reference_jwt,'.',3);

  RETURN v_sig = _b64url(extensions.hmac(v_input, v_secret, 'sha256'));
END $$;

REVOKE ALL ON FUNCTION verify_jwt_secret(text) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- SELF-TEST. Same principle as 0002: prove the thing runs before committing.
-- If the Vault secret is missing, sign_jwt raises and this aborts the txn.
--
-- NOTE: this proves sign_jwt RUNS. It cannot prove the secret is CORRECT - that
-- needs a reference token, which is why verify_jwt_secret() above exists and why
-- the runbook makes calling it a mandatory step.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_token text;
BEGIN
  v_token := sign_jwt(jsonb_build_object('role','authenticated','test',true));
  IF array_length(string_to_array(v_token, '.'), 1) <> 3 THEN
    RAISE EXCEPTION 'ABORT: sign_jwt did not produce a 3-segment JWT.';
  END IF;
  RAISE NOTICE 'sign_jwt self-test passed.';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
