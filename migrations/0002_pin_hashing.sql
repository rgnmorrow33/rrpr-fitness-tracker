-- ============================================================================
-- 0002_pin_hashing.sql
-- PIN hashing pass (item 3 of the post-v4.45 work order).
--
-- What this does:
--   1. Moves per-trainer PINs out of trainers.pin (plaintext, anon-readable)
--      into trainer_pins (bcrypt hash, no anon access).
--   2. Hashes the front desk / admin PIN in the settings row in place.
--   3. Adds verify/set RPC functions so raw PINs never leave the database
--      and are never stored, echoed, or logged.
--   4. Adds a basic attempt throttle: 5 failures in 15 minutes locks the
--      scope for 5 minutes. Needed because the verify functions are
--      executable with the public anon key.
--
-- Pairs with: 0003_rls_policies.sql and the app PIN changes (staged in
-- staging/RoundRock_Fitness_Tracker.staging.html). The OLD app cannot sign
-- anyone in after this runs (it compares plaintext client-side and pins are
-- nulled below), so this migration and the app deploy land together at
-- go-live. See docs/RLS_GO_LIVE_RUNBOOK.md for sequencing.
--
-- STAGING FIRST. Do not run against production until the runbook says so.
-- Idempotent: safe to run twice.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS trainer_pins (
  trainer_id uuid PRIMARY KEY REFERENCES trainers(id) ON DELETE CASCADE,
  pin_hash   text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pin_attempts (
  scope         text PRIMARY KEY,   -- 'admin' or 'trainer:<uuid>'
  fails         int NOT NULL DEFAULT 0,
  first_fail_at timestamptz,
  locked_until  timestamptz
);

-- App reads pin_set to know whether a sign-in tile is usable. Maintained by
-- set_trainer_pin() below; the app never writes it directly.
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS pin_set boolean NOT NULL DEFAULT false;

-- ----------------------------------------------------------------------------
-- Backfill: hash existing plaintext PINs, then remove the plaintext.
-- btrim(.., '"') defends against a value that was stored JSON-quoted.
-- ----------------------------------------------------------------------------

INSERT INTO trainer_pins (trainer_id, pin_hash)
SELECT id, crypt(btrim(pin, '"'), gen_salt('bf'))
FROM trainers
WHERE pin IS NOT NULL AND btrim(pin, '"') <> ''
ON CONFLICT (trainer_id) DO NOTHING;

UPDATE trainers t
SET pin_set = true
WHERE pin_set = false
  AND EXISTS (SELECT 1 FROM trainer_pins p WHERE p.trainer_id = t.id);

UPDATE trainers SET pin = NULL WHERE pin IS NOT NULL;

-- Admin PIN: hash in place unless it already looks like a bcrypt hash.
UPDATE settings
SET value = crypt(btrim(value, '"'), gen_salt('bf')), updated_at = now()
WHERE key = 'admin_pin' AND value !~ '^\$2[abxy]\$';

-- ----------------------------------------------------------------------------
-- Throttle helpers (internal; no anon EXECUTE)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _pin_locked(p_scope text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_until timestamptz;
BEGIN
  SELECT locked_until INTO v_until FROM pin_attempts WHERE scope = p_scope;
  RETURN v_until IS NOT NULL AND v_until > now();
END $$;

CREATE OR REPLACE FUNCTION _pin_record(p_scope text, p_ok boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_ok THEN
    DELETE FROM pin_attempts WHERE scope = p_scope;
    RETURN;
  END IF;
  INSERT INTO pin_attempts (scope, fails, first_fail_at, locked_until)
  VALUES (p_scope, 1, now(), NULL)
  ON CONFLICT (scope) DO UPDATE SET
    fails = CASE
      WHEN pin_attempts.first_fail_at IS NULL
        OR pin_attempts.first_fail_at < now() - interval '15 minutes'
      THEN 1 ELSE pin_attempts.fails + 1 END,
    first_fail_at = CASE
      WHEN pin_attempts.first_fail_at IS NULL
        OR pin_attempts.first_fail_at < now() - interval '15 minutes'
      THEN now() ELSE pin_attempts.first_fail_at END,
    locked_until = CASE
      WHEN (CASE
        WHEN pin_attempts.first_fail_at IS NULL
          OR pin_attempts.first_fail_at < now() - interval '15 minutes'
        THEN 1 ELSE pin_attempts.fails + 1 END) >= 5
      THEN now() + interval '5 minutes' ELSE NULL END;
END $$;

-- ----------------------------------------------------------------------------
-- Public RPCs. All return a status text: 'ok' | 'wrong' | 'locked' |
-- 'unset' | 'invalid'. Raw PIN values are parameters only - never stored,
-- never returned, never raised in an error, never logged.
-- ----------------------------------------------------------------------------

-- NOTE (2026-07-13): search_path MUST include `extensions`. pgcrypto is
-- installed in the `extensions` schema on Supabase (verified on prod and on a
-- test branch), so crypt() and gen_salt() are NOT resolvable from
-- `public, pg_temp`. Without `extensions` here, this function throws
-- "function crypt(text, text) does not exist" at runtime - AFTER the backfill
-- above has already nulled every plaintext PIN. Net effect: total sign-in
-- lockout with no rollback path. Caught on a staging branch before go-live.
-- Applies to all four crypt-using functions below.
CREATE OR REPLACE FUNCTION verify_admin_pin(p_pin text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_hash text;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^\d{4}$' THEN RETURN 'wrong'; END IF;
  IF _pin_locked('admin') THEN RETURN 'locked'; END IF;
  SELECT value INTO v_hash FROM settings WHERE key = 'admin_pin';
  IF v_hash IS NULL THEN RETURN 'unset'; END IF;
  IF v_hash = crypt(p_pin, v_hash) THEN
    PERFORM _pin_record('admin', true);
    RETURN 'ok';
  END IF;
  PERFORM _pin_record('admin', false);
  RETURN CASE WHEN _pin_locked('admin') THEN 'locked' ELSE 'wrong' END;
END $$;

CREATE OR REPLACE FUNCTION set_admin_pin(p_current text, p_new text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_hash text;
BEGIN
  IF p_new IS NULL OR p_new !~ '^\d{4}$' THEN RETURN 'invalid'; END IF;
  SELECT value INTO v_hash FROM settings WHERE key = 'admin_pin';
  IF v_hash IS NOT NULL THEN
    -- A PIN exists: changing it requires the current one.
    IF _pin_locked('admin') THEN RETURN 'locked'; END IF;
    IF p_current IS NULL OR v_hash <> crypt(p_current, v_hash) THEN
      PERFORM _pin_record('admin', false);
      RETURN CASE WHEN _pin_locked('admin') THEN 'locked' ELSE 'wrong' END;
    END IF;
    PERFORM _pin_record('admin', true);
  END IF;
  INSERT INTO settings (key, value, updated_at)
  VALUES ('admin_pin', crypt(p_new, gen_salt('bf')), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN 'ok';
END $$;

CREATE OR REPLACE FUNCTION verify_trainer_pin(p_trainer_id uuid, p_pin text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_hash text; v_scope text;
BEGIN
  IF p_trainer_id IS NULL OR p_pin IS NULL OR p_pin !~ '^\d{4}$' THEN RETURN 'wrong'; END IF;
  v_scope := 'trainer:' || p_trainer_id::text;
  IF _pin_locked(v_scope) THEN RETURN 'locked'; END IF;
  SELECT pin_hash INTO v_hash FROM trainer_pins WHERE trainer_id = p_trainer_id;
  IF v_hash IS NULL THEN RETURN 'unset'; END IF;
  IF v_hash = crypt(p_pin, v_hash) THEN
    PERFORM _pin_record(v_scope, true);
    RETURN 'ok';
  END IF;
  PERFORM _pin_record(v_scope, false);
  RETURN CASE WHEN _pin_locked(v_scope) THEN 'locked' ELSE 'wrong' END;
END $$;

-- Setting a trainer PIN is not server-gated beyond the anon key. Client-side
-- this sits behind ctx.can('canSetPINs'), which matches the current posture
-- (anyone holding the anon key already has full operational table access).
-- Tighten to real auth at the APC gate.
CREATE OR REPLACE FUNCTION set_trainer_pin(p_trainer_id uuid, p_new text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
BEGIN
  IF p_new IS NULL OR p_new !~ '^\d{4}$' THEN RETURN 'invalid'; END IF;
  IF NOT EXISTS (SELECT 1 FROM trainers WHERE id = p_trainer_id) THEN RETURN 'invalid'; END IF;
  INSERT INTO trainer_pins (trainer_id, pin_hash, updated_at)
  VALUES (p_trainer_id, crypt(p_new, gen_salt('bf')), now())
  ON CONFLICT (trainer_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, updated_at = now();
  UPDATE trainers SET pin_set = true, updated_at = now() WHERE id = p_trainer_id;
  RETURN 'ok';
END $$;

-- ----------------------------------------------------------------------------
-- Lockdown: PIN tables get no anon/authenticated access at all. RLS is also
-- enabled with no policies (belt and suspenders; SECURITY DEFINER functions
-- run as owner and still work).
-- ----------------------------------------------------------------------------

REVOKE ALL ON TABLE trainer_pins FROM anon, authenticated;
REVOKE ALL ON TABLE pin_attempts FROM anon, authenticated;
ALTER TABLE trainer_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE pin_attempts ENABLE ROW LEVEL SECURITY;

REVOKE EXECUTE ON FUNCTION _pin_locked(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION _pin_record(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_admin_pin(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_admin_pin(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_trainer_pin(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_trainer_pin(uuid, text) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- SELF-TEST. Do not remove.
--
-- This migration destroys every plaintext PIN (UPDATE trainers SET pin = NULL,
-- above) and hands sign-in over to the RPCs below. If those RPCs are broken,
-- the team is locked out of the app with no rollback path: the old HTML cannot
-- be redeployed because the plaintext PINs it compares against are gone.
--
-- So: actually call the RPC before committing. If it raises (the crypt/
-- search_path failure this file shipped with until 2026-07-13, caught on a
-- staging branch), the exception aborts the transaction and NOTHING above is
-- committed. Plaintext PINs survive, the app keeps working, and you get a loud
-- error instead of a silent morning-of disaster.
-- ----------------------------------------------------------------------------

DO $$
DECLARE v_id uuid; v_res text;
BEGIN
  SELECT trainer_id INTO v_id FROM trainer_pins LIMIT 1;

  IF v_id IS NULL THEN
    RAISE NOTICE 'PIN self-test skipped: no PINs present to test against.';
    RETURN;
  END IF;

  -- Deliberately wrong PIN. We are testing that the function RUNS, not that it
  -- authenticates. A crypt/search_path failure raises here and aborts the txn.
  v_res := verify_trainer_pin(v_id, '0000');

  IF v_res NOT IN ('ok', 'wrong', 'locked', 'unset') THEN
    RAISE EXCEPTION 'ABORT: verify_trainer_pin self-test returned unexpected value: %', v_res;
  END IF;

  -- Undo the failed-attempt counter our probe just incremented.
  DELETE FROM pin_attempts WHERE scope = 'trainer:' || v_id::text;

  -- Same check for the admin PIN path (exercises crypt() in verify_admin_pin).
  IF EXISTS (SELECT 1 FROM settings WHERE key = 'admin_pin') THEN
    v_res := verify_admin_pin('0000');
    IF v_res NOT IN ('ok', 'wrong', 'locked', 'unset') THEN
      RAISE EXCEPTION 'ABORT: verify_admin_pin self-test returned unexpected value: %', v_res;
    END IF;
    DELETE FROM pin_attempts WHERE scope = 'admin';
  END IF;

  RAISE NOTICE 'PIN RPC self-test passed. Safe to commit.';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
