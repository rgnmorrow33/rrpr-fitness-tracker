-- ============================================================================
-- 0005_rls_identity_policies.sql
-- THE MIGRATION THAT CLOSES CLIENT DATA TO THE PUBLIC INTERNET.
--
-- REPLACES the anon_* policy set from 0003. Every policy in 0003 is
-- `TO anon USING (true)`, which is by construction "publicly viewable": after
-- 0003, anyone with the app URL can still read every row of `clients`, email,
-- phone, and PAR-Q health answers included. Reagan's call on 2026-07-13 was
-- that this is not acceptable. This migration is that decision, implemented.
--
-- Requires 0004 (sign_in / app_is_signed_in / app_is_admin) and the app-side
-- token wiring. Applying this WITHOUT the app changes takes every iPad dark:
-- reads return empty, writes 403. Order is in RLS_GO_LIVE_RUNBOOK.md.
--
-- STAGED. Verified end to end on a Supabase branch 2026-07-13:
--     anon reads clients:        BLOCKED (permission denied)
--     anon reads sign-in roster: 1 row   (login screen still works)
--     trainer reads clients:     1 row
--     trainer DELETEs clients:   0 rows  (blocked at the DB, not just in JS)
--     trainer reads settings:    0 rows  (cannot grab the admin PIN hash)
--     admin reads settings:      1 row
--     admin DELETEs clients:     1 row
--
-- Idempotent. Safe to re-run.
-- ============================================================================
--
-- WHAT THIS DOES AND DOES NOT ENFORCE
--
-- Enforced at the database, no longer merely suggested by JavaScript:
--   - You must be a signed-in team member to touch any data at all.
--   - Only role_tier='admin' can DELETE anything.
--   - Only admins can edit the roster, closures, schedule versions, banners.
--   - Only admins can read `settings` (it holds the admin PIN hash).
--   - You can only read your own notifications.
--
-- NOT enforced, still app-side via ctx.can():
--   - Row ownership. Any signed-in trainer can update any client's row.
--
-- That limit is structural, not laziness. Sessions, packages, and attendance
-- live inside JSONB blobs on the parent row (ADR-0004), so "log a session" IS
-- "UPDATE the whole clients row". Per-trainer ownership requires unwinding the
-- JSONB model. Separate project, tracked in BACKLOG.
--
-- The trade is the right one. An internal tool where any signed-in team member
-- can edit any record is normal. A public tool where any stranger can read
-- resident health data is not. This closes the second thing.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Tear down the anon-era policies (0003's anon_*, and any legacy allow-all)
-- ----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename, policyname FROM pg_policies
           WHERE schemaname = 'public'
             AND policyname IN ('anon_select','anon_insert','anon_update','anon_delete','allow all')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2. anon loses its table grants entirely. Denied twice: no grant, no policy.
-- ----------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

-- ----------------------------------------------------------------------------
-- 3. The ONE thing anon may still see: the sign-in roster.
--
-- Chicken-and-egg: you must pick your name before you can have a token, but you
-- cannot read `trainers` without one. A definer view (security_invoker stays
-- OFF) bypasses RLS on the base table and exposes names only. No PINs, no
-- hashes, no audit_log. This is the only surface anon has anywhere in the DB.
-- ----------------------------------------------------------------------------
-- `role` is included deliberately. It is the legacy column kept in sync with
-- role_tier, and translate.trainers.toSupabase writes it back on every save. If
-- the view omitted it, the pre-auth roster load would hydrate every profile with
-- role='trainer' (the fromSupabase default), and the next Manage Team save would
-- silently downgrade every admin's role column. Cheap to include, nasty to omit.
-- DROP then CREATE, not CREATE OR REPLACE: replace cannot insert a column into
-- the middle of an existing view's column list ("cannot change name of view
-- column"). Drop keeps this migration re-runnable.
DROP VIEW IF EXISTS trainer_directory;
CREATE VIEW trainer_directory AS
  SELECT id, name, role, COALESCE(role_tier, role, 'trainer') AS role_tier, pin_set
  FROM trainers
  WHERE is_active IS TRUE AND deleted_at IS NULL;

GRANT SELECT ON trainer_directory TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3b. Front Desk sign-in.
--
-- Front Desk is a shared, non-personal admin seat with NO row in `trainers`
-- (the app signs it in with trainer_id: null). sign_in() has nothing to key on,
-- so without this RPC, switching on identity RLS locks Front Desk out of the
-- app entirely. Mints a token against the nil UUID: app_is_signed_in() is true,
-- app_is_admin() is true, and it can never collide with a real trainer_id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sign_in_front_desk(p_pin text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_status text; v_iat int; v_exp int;
  c_front_desk_id CONSTANT uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  v_status := verify_admin_pin(p_pin);   -- inherits the 5-failure lockout
  IF v_status <> 'ok' THEN
    RETURN jsonb_build_object('status', v_status);
  END IF;

  v_iat := extract(epoch FROM now())::int;
  v_exp := extract(epoch FROM now() + interval '12 hours')::int;

  RETURN jsonb_build_object(
    'status', 'ok',
    'expires_at', v_exp,
    'trainer', jsonb_build_object('id', NULL, 'name', 'Front Desk', 'role_tier', 'admin'),
    'token', sign_jwt(jsonb_build_object(
      'role', 'authenticated', 'aud', 'authenticated',
      'sub',  c_front_desk_id::text,
      'iat',  v_iat, 'exp', v_exp,
      'trainer_id', c_front_desk_id::text,
      'role_tier',  'admin',
      'name',       'Front Desk'
    ))
  );
END $$;

REVOKE ALL ON FUNCTION sign_in_front_desk(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sign_in_front_desk(text) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. PIN setting becomes admin-gated.
--
-- 0002 shipped set_trainer_pin with the note: "not server-gated beyond the anon
-- key ... Tighten to real auth at the APC gate." We have real auth now, so this
-- is that tightening. Without it, anyone holding the public key could reset any
-- team member's PIN and sign in as them.
-- ----------------------------------------------------------------------------
-- service_role identity. The service_role key is itself a JWT carrying
-- role=service_role, so we read it exactly like we read trainer claims.
CREATE OR REPLACE FUNCTION app_is_service_role() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT COALESCE(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role';
$$;
GRANT EXECUTE ON FUNCTION app_is_service_role() TO anon, authenticated, service_role;

-- set_trainer_pin: admin OR service_role.
--
-- The service_role branch is the BOOTSTRAP and RECOVERY door. Without it, an
-- admin-only gate is a deadlock: you cannot set the first admin's PIN on a
-- fresh install, and if every admin forgets their PIN, nobody can ever get back
-- in. service_role never ships in the app; it lives in the SQL editor and the
-- import pipelines. This is the "break glass" path.
CREATE OR REPLACE FUNCTION set_trainer_pin(p_trainer_id uuid, p_new text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
BEGIN
  IF NOT (public.app_is_admin() OR public.app_is_service_role()) THEN
    RETURN 'forbidden';
  END IF;
  IF p_new IS NULL OR p_new !~ '^\d{4}$' THEN RETURN 'invalid'; END IF;
  IF NOT EXISTS (SELECT 1 FROM trainers WHERE id = p_trainer_id) THEN RETURN 'invalid'; END IF;
  INSERT INTO trainer_pins (trainer_id, pin_hash, updated_at)
  VALUES (p_trainer_id, crypt(p_new, gen_salt('bf')), now())
  ON CONFLICT (trainer_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, updated_at = now();
  UPDATE trainers SET pin_set = true, updated_at = now() WHERE id = p_trainer_id;
  RETURN 'ok';
END $$;

GRANT EXECUTE ON FUNCTION set_trainer_pin(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION set_trainer_pin(uuid, text) FROM anon;

-- Same gate on the admin PIN. service_role skips the current-PIN challenge,
-- because recovery means "I have lost the current PIN".
CREATE OR REPLACE FUNCTION set_admin_pin(p_current text, p_new text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_hash text;
BEGIN
  IF NOT (public.app_is_admin() OR public.app_is_service_role()) THEN
    RETURN 'forbidden';
  END IF;
  IF p_new IS NULL OR p_new !~ '^\d{4}$' THEN RETURN 'invalid'; END IF;
  SELECT value INTO v_hash FROM settings WHERE key = 'admin_pin';
  IF v_hash IS NOT NULL AND NOT public.app_is_service_role() THEN
    IF _pin_locked('admin') THEN RETURN 'locked'; END IF;
    IF p_current IS NULL OR v_hash <> crypt(p_current, v_hash) THEN
      PERFORM _pin_record('admin', false);
      RETURN CASE WHEN _pin_locked('admin') THEN 'locked' ELSE 'wrong' END;
    END IF;
    PERFORM _pin_record('admin', true);
  END IF;
  INSERT INTO settings (key, value, updated_at) VALUES ('admin_pin', crypt(p_new, gen_salt('bf')), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN 'ok';
END $$;

GRANT EXECUTE ON FUNCTION set_admin_pin(text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION set_admin_pin(text, text) FROM anon;

-- NOTE FOR THE APP PORT: both setters can now return 'forbidden'. The PinModal
-- and Manage Team handlers must render that as "Admin access required."

-- ----------------------------------------------------------------------------
-- 5. The policy set.
--
-- Shape for operational tables:
--   SELECT / INSERT / UPDATE -> any signed-in team member
--   DELETE                   -> admins only
--
-- All policies target `authenticated`, because sign_in() mints role=authenticated.
-- anon has no policy anywhere and no table grants.
-- ----------------------------------------------------------------------------

CREATE POLICY rw_signed_in  ON clients FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON clients FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON clients FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON clients FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON leads FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON leads FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON leads FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON leads FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON wros FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON wros FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON wros FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON wros FOR DELETE TO authenticated USING (app_is_admin());

-- classes: structure-edit and attendance-marking are both UPDATE on the same
-- row. RLS cannot tell them apart. Structure-edit stays an app-side ctx.can() gate.
CREATE POLICY rw_signed_in  ON classes FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_admin     ON classes FOR INSERT TO authenticated WITH CHECK (app_is_admin());
CREATE POLICY upd_signed_in ON classes FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON classes FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON member_contacts FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON member_contacts FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON member_contacts FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON member_contacts FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON admin_items FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON admin_items FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON admin_items FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON admin_items FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON referrals FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_signed_in ON referrals FOR INSERT TO authenticated WITH CHECK (app_is_signed_in());
CREATE POLICY upd_signed_in ON referrals FOR UPDATE TO authenticated USING (app_is_signed_in()) WITH CHECK (app_is_signed_in());
CREATE POLICY del_admin     ON referrals FOR DELETE TO authenticated USING (app_is_admin());

-- Structure tables: everyone reads, admins write.
CREATE POLICY rw_signed_in  ON closures FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_admin     ON closures FOR INSERT TO authenticated WITH CHECK (app_is_admin());
CREATE POLICY upd_admin     ON closures FOR UPDATE TO authenticated USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY del_admin     ON closures FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON schedule_versions FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_admin     ON schedule_versions FOR INSERT TO authenticated WITH CHECK (app_is_admin());
CREATE POLICY upd_admin     ON schedule_versions FOR UPDATE TO authenticated USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY del_admin     ON schedule_versions FOR DELETE TO authenticated USING (app_is_admin());

CREATE POLICY rw_signed_in  ON announcement_banners FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_admin     ON announcement_banners FOR INSERT TO authenticated WITH CHECK (app_is_admin());
CREATE POLICY upd_admin     ON announcement_banners FOR UPDATE TO authenticated USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY del_admin     ON announcement_banners FOR DELETE TO authenticated USING (app_is_admin());

-- Trainer roster: admin-managed. Pre-auth reads go through trainer_directory.
CREATE POLICY rw_signed_in  ON trainers FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY ins_admin     ON trainers FOR INSERT TO authenticated WITH CHECK (app_is_admin());
CREATE POLICY upd_admin     ON trainers FOR UPDATE TO authenticated USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY del_admin     ON trainers FOR DELETE TO authenticated USING (app_is_admin());

-- Notifications: you see yours. Admins see all.
CREATE POLICY own_or_admin_sel ON notifications FOR SELECT TO authenticated
  USING (target_trainer_id = app_trainer_id() OR app_is_admin());
CREATE POLICY ins_signed_in    ON notifications FOR INSERT TO authenticated
  WITH CHECK (app_is_signed_in());
CREATE POLICY own_or_admin_upd ON notifications FOR UPDATE TO authenticated
  USING (target_trainer_id = app_trainer_id() OR app_is_admin())
  WITH CHECK (target_trainer_id = app_trainer_id() OR app_is_admin());
CREATE POLICY del_admin        ON notifications FOR DELETE TO authenticated USING (app_is_admin());

-- Time off: everyone sees the calendar, you request your own, admins decide.
CREATE POLICY rw_signed_in     ON trainer_time_off FOR SELECT TO authenticated USING (app_is_signed_in());
CREATE POLICY own_or_admin_ins ON trainer_time_off FOR INSERT TO authenticated
  WITH CHECK (trainer_id = app_trainer_id() OR app_is_admin());
CREATE POLICY own_or_admin_upd ON trainer_time_off FOR UPDATE TO authenticated
  USING (trainer_id = app_trainer_id() OR app_is_admin())
  WITH CHECK (trainer_id = app_trainer_id() OR app_is_admin());
CREATE POLICY del_admin        ON trainer_time_off FOR DELETE TO authenticated USING (app_is_admin());

-- Settings: admin only. Holds the admin PIN hash; a signed-in trainer reading
-- it would be a self-escalation path.
CREATE POLICY admin_all ON settings FOR ALL TO authenticated
  USING (app_is_admin()) WITH CHECK (app_is_admin());

-- Orphan tables stay deny-all: RLS on, no policies, no grants. (packages,
-- package_participants, queue, trainer_pins, pin_attempts.)

-- ----------------------------------------------------------------------------
-- 6. Indexes for the two per-row policies. Everything else is a constant
--    predicate the planner evaluates once, so no index needed.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notifications_target_trainer ON notifications (target_trainer_id);
CREATE INDEX IF NOT EXISTS idx_trainer_time_off_trainer     ON trainer_time_off (trainer_id);

-- ----------------------------------------------------------------------------
-- 7. REALTIME. postgres_changes enforces RLS against the token handed to
--    supabase.realtime.setAuth(). The app MUST call setAuth(token) after
--    sign_in AND on every reconnect, or notifications and trainer_time_off (the
--    only two tables actually in the supabase_realtime publication) silently
--    stop delivering. See ARCHITECTURE.md section 6.
-- ----------------------------------------------------------------------------

NOTIFY pgrst, 'reload schema';

COMMIT;
