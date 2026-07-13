-- ============================================================================
-- rls_emergency_rollback.sql
-- EMERGENCY USE ONLY. Disables RLS on every table if the production flip
-- goes sideways (app can't load, pipelines fail, anything unexplained).
--
-- What this restores: the pre-flip open-DB posture. App and pipelines work
-- exactly as before the flip.
--
-- What this does NOT undo: PIN hashing (0002). Plaintext PINs are gone and
-- stay gone. The updated app verifies via RPC, which works with RLS on or
-- off, so sign-in keeps working after this rollback. Do NOT redeploy the
-- old app HTML - it expects plaintext pins that no longer exist.
--
-- Policies are left in place (harmless while RLS is disabled), so re-flipping
-- later is just re-running the ENABLE statements in 0003.
-- ============================================================================

BEGIN;

ALTER TABLE admin_items          DISABLE ROW LEVEL SECURITY;
ALTER TABLE announcement_banners DISABLE ROW LEVEL SECURITY;
ALTER TABLE classes              DISABLE ROW LEVEL SECURITY;
ALTER TABLE clients              DISABLE ROW LEVEL SECURITY;
ALTER TABLE closures             DISABLE ROW LEVEL SECURITY;
ALTER TABLE leads                DISABLE ROW LEVEL SECURITY;
ALTER TABLE member_contacts      DISABLE ROW LEVEL SECURITY;
ALTER TABLE notifications        DISABLE ROW LEVEL SECURITY;
ALTER TABLE referrals            DISABLE ROW LEVEL SECURITY;
ALTER TABLE schedule_versions    DISABLE ROW LEVEL SECURITY;
ALTER TABLE settings             DISABLE ROW LEVEL SECURITY;
ALTER TABLE trainers             DISABLE ROW LEVEL SECURITY;
ALTER TABLE trainer_time_off     DISABLE ROW LEVEL SECURITY;
ALTER TABLE wros                 DISABLE ROW LEVEL SECURITY;
ALTER TABLE packages             DISABLE ROW LEVEL SECURITY;
ALTER TABLE package_participants DISABLE ROW LEVEL SECURITY;
ALTER TABLE queue                DISABLE ROW LEVEL SECURITY;

-- Keep the PIN tables locked even in a rollback. The verify/set RPCs are
-- SECURITY DEFINER and unaffected. Note: settings RLS is disabled above,
-- which re-exposes the admin_pin row to anon reads - it now holds a bcrypt
-- hash, not a plaintext PIN, so exposure is bounded. Re-enable ASAP.
-- (trainer_pins / pin_attempts intentionally NOT disabled.)

NOTIFY pgrst, 'reload schema';

COMMIT;
