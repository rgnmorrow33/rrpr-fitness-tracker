-- ============================================================================
-- 0003_rls_policies.sql
-- RLS enable + policy set (item 3 of the post-v4.45 work order).
--
-- Access model:
--   anon (the committed key in the app)
--     - SELECT / INSERT / UPDATE on the operational tables the app uses.
--     - DELETE only on announcement_banners (the app's only hard delete;
--       everything else soft-deletes via deleted_at).
--     - settings: everything EXCEPT the admin_pin row, which is reachable
--       only through the verify/set RPCs from 0002.
--     - NO access: trainer_pins, pin_attempts, packages,
--       package_participants, queue.
--   service_role (pipelines; has BYPASSRLS)
--     - unaffected by any policy here. Both imports move to this key.
--   postgres (Supabase SQL editor)
--     - table owner, bypasses RLS. Manual SQL keeps working.
--
-- Known limitation, on the record: the anon key is public by design, so for
-- the operational tables these policies grant the internet the same access
-- the app has. The real wins are the PIN/settings lockdown, pipelines off
-- the anon key, the three unused tables closed, and the policy scaffolding
-- being in place so per-user auth (APC gate) is a policy edit, not a
-- rebuild.
--
-- Realtime note: postgres_changes respects RLS. trainer_time_off and
-- notifications (the only two tables in the supabase_realtime publication)
-- both get anon SELECT below, so live sync keeps working.
--
-- STAGING FIRST. Idempotent: safe to run twice.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- STEP 0 - DROP THE LEGACY "allow all" POLICIES. DO NOT SKIP.
--
-- Twelve tables already carry a policy named `allow all`, created at some point
-- before this pass and sitting inert because RLS was never enabled:
--
--     FOR ALL TO anon USING (true) WITH CHECK (true)
--
-- Postgres OR's permissive policies together. The moment RLS is enabled, that
-- policy is evaluated alongside everything below and grants anon full ALL
-- access (including DELETE) regardless of what the new policies say. Every
-- restriction in this file that is narrower than "true" is silently defeated.
--
-- Verified by reproduction 2026-07-13 on a throwaway table: with `allow all`
-- present alongside `anon_select ... USING (key <> 'admin_pin')`, anon still
-- read the admin_pin row. Dropping `allow all` and changing nothing else, anon
-- read zero admin_pin rows.
--
-- Concretely, without these DROPs this migration FAILS to deliver three of its
-- four stated wins:
--   1. "hard deletes closed except banners" - false. `allow all` is FOR ALL,
--      so anon keeps DELETE on clients, classes, wros, leads, and the rest.
--   2. "admin_pin row unreachable via anon" - false. `allow all` on settings
--      overrides the key <> 'admin_pin' filter below.
--   3. "queue closed to anon" - false. queue has an `allow all` policy, so the
--      no-policy deny-by-default further down never takes effect for it.
--      (packages and package_participants have no legacy policy and ARE closed.)
--
-- The PIN table lockdown from 0002 is unaffected: trainer_pins and pin_attempts
-- are new tables and never had a legacy policy.
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS "allow all" ON admin_items;
DROP POLICY IF EXISTS "allow all" ON classes;
DROP POLICY IF EXISTS "allow all" ON clients;
DROP POLICY IF EXISTS "allow all" ON closures;
DROP POLICY IF EXISTS "allow all" ON leads;
DROP POLICY IF EXISTS "allow all" ON member_contacts;
DROP POLICY IF EXISTS "allow all" ON queue;
DROP POLICY IF EXISTS "allow all" ON referrals;
DROP POLICY IF EXISTS "allow all" ON schedule_versions;
DROP POLICY IF EXISTS "allow all" ON settings;
DROP POLICY IF EXISTS "allow all" ON trainers;
DROP POLICY IF EXISTS "allow all" ON wros;

-- Post-flip assertion. If any `allow all` survives, this migration aborts
-- rather than shipping a database that looks locked and is not.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'public' AND policyname = 'allow all';
  IF n > 0 THEN
    RAISE EXCEPTION 'ABORT: % legacy "allow all" policies still present. RLS would be cosmetic.', n;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- Operational tables: anon select/insert/update
-- ----------------------------------------------------------------------------

ALTER TABLE admin_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON admin_items;
DROP POLICY IF EXISTS anon_insert ON admin_items;
DROP POLICY IF EXISTS anon_update ON admin_items;
CREATE POLICY anon_select ON admin_items FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON admin_items FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON admin_items FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE classes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON classes;
DROP POLICY IF EXISTS anon_insert ON classes;
DROP POLICY IF EXISTS anon_update ON classes;
CREATE POLICY anon_select ON classes FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON classes FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON classes FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON clients;
DROP POLICY IF EXISTS anon_insert ON clients;
DROP POLICY IF EXISTS anon_update ON clients;
CREATE POLICY anon_select ON clients FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON clients FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON clients FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE closures ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON closures;
DROP POLICY IF EXISTS anon_insert ON closures;
DROP POLICY IF EXISTS anon_update ON closures;
CREATE POLICY anon_select ON closures FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON closures FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON closures FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON leads;
DROP POLICY IF EXISTS anon_insert ON leads;
DROP POLICY IF EXISTS anon_update ON leads;
CREATE POLICY anon_select ON leads FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON leads FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON leads FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE member_contacts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON member_contacts;
DROP POLICY IF EXISTS anon_insert ON member_contacts;
DROP POLICY IF EXISTS anon_update ON member_contacts;
CREATE POLICY anon_select ON member_contacts FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON member_contacts FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON member_contacts FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON notifications;
DROP POLICY IF EXISTS anon_insert ON notifications;
DROP POLICY IF EXISTS anon_update ON notifications;
CREATE POLICY anon_select ON notifications FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON notifications FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON notifications FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON referrals;
DROP POLICY IF EXISTS anon_insert ON referrals;
DROP POLICY IF EXISTS anon_update ON referrals;
CREATE POLICY anon_select ON referrals FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON referrals FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON referrals FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE schedule_versions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON schedule_versions;
DROP POLICY IF EXISTS anon_insert ON schedule_versions;
DROP POLICY IF EXISTS anon_update ON schedule_versions;
CREATE POLICY anon_select ON schedule_versions FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON schedule_versions FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON schedule_versions FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE trainers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON trainers;
DROP POLICY IF EXISTS anon_insert ON trainers;
DROP POLICY IF EXISTS anon_update ON trainers;
CREATE POLICY anon_select ON trainers FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON trainers FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON trainers FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE trainer_time_off ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON trainer_time_off;
DROP POLICY IF EXISTS anon_insert ON trainer_time_off;
DROP POLICY IF EXISTS anon_update ON trainer_time_off;
CREATE POLICY anon_select ON trainer_time_off FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON trainer_time_off FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON trainer_time_off FOR UPDATE TO anon USING (true) WITH CHECK (true);

ALTER TABLE wros ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON wros;
DROP POLICY IF EXISTS anon_insert ON wros;
DROP POLICY IF EXISTS anon_update ON wros;
CREATE POLICY anon_select ON wros FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON wros FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON wros FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- announcement_banners: the app's only hard DELETE
-- ----------------------------------------------------------------------------

ALTER TABLE announcement_banners ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON announcement_banners;
DROP POLICY IF EXISTS anon_insert ON announcement_banners;
DROP POLICY IF EXISTS anon_update ON announcement_banners;
DROP POLICY IF EXISTS anon_delete ON announcement_banners;
CREATE POLICY anon_select ON announcement_banners FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert ON announcement_banners FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY anon_update ON announcement_banners FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_delete ON announcement_banners FOR DELETE TO anon USING (true);

-- ----------------------------------------------------------------------------
-- settings: everything except the admin_pin row (RPC-only from 0002)
-- ----------------------------------------------------------------------------

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON settings;
DROP POLICY IF EXISTS anon_insert ON settings;
DROP POLICY IF EXISTS anon_update ON settings;
CREATE POLICY anon_select ON settings FOR SELECT TO anon USING (key <> 'admin_pin');
CREATE POLICY anon_insert ON settings FOR INSERT TO anon WITH CHECK (key <> 'admin_pin');
CREATE POLICY anon_update ON settings FOR UPDATE TO anon
  USING (key <> 'admin_pin') WITH CHECK (key <> 'admin_pin');

-- ----------------------------------------------------------------------------
-- Deny-by-default tables. Neither the app nor the daily pipelines touch
-- these three (verified July 2026: no .from() call sites in the app, no
-- REST paths in either import). The rectrac-import tool emits CSVs for
-- manual SQL editor inserts, which bypass RLS as table owner. RLS on, no
-- policies = anon sees nothing and writes nothing. If something unexpected
-- breaks after the flip, look here first, then check pg logs.
-- ----------------------------------------------------------------------------

ALTER TABLE packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE package_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE queue ENABLE ROW LEVEL SECURITY;

-- trainer_pins / pin_attempts already locked in 0002; re-assert harmlessly.
ALTER TABLE trainer_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE pin_attempts ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';

COMMIT;
