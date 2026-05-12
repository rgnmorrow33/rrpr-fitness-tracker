-- Pre-alpha wipe of test client data
-- Run in the Supabase SQL editor BEFORE Reagan runs the bulk CSV import.
-- Selisa to execute, then notify Reagan, then Reagan runs the import.
--
-- What this clears:
--   - clients (all rows; cascades to JSONB sessions, packages, audit_log on each row)
--   - leads (the consult queue - real table name is 'leads', not 'leads_queue')
--
-- What this leaves alone:
--   - closures (real 2026 holiday data)
--   - announcement_banners
--   - trainers (the roster - retired trainers handled via is_active flag)
--   - schedule_versions (GX schedule history)
--   - admin_items / member_contacts / referrals / wros (Selisa: review and
--     extend this script if any of these need wiping too)
--   - trainer_time_off (KEEP unless Selisa confirms rows are pre-alpha test data;
--     uncomment the DELETE below if so)
--
-- Carryforward from v4.7 (May 11): PostgREST schema-cache reload at the end
-- to avoid the stale-cache class of bug the lead-save chase surfaced.

BEGIN;

-- Wipe all clients (cascades to JSONB sessions, packages, audit_log on each row).
DELETE FROM clients;

-- Wipe consult queue / leads pipeline (pre-alpha test data).
DELETE FROM leads;

-- Optional: wipe trainer time off if Selisa confirms current rows are test data.
-- Uncomment below if so. Leave commented to keep production time-off records.
-- DELETE FROM trainer_time_off;

-- Optional follow-ups (Selisa: uncomment any that hold pre-alpha test data only):
-- DELETE FROM member_contacts;
-- DELETE FROM referrals;
-- DELETE FROM admin_items;
-- DELETE FROM wros;

-- Refresh PostgREST schema cache. Idempotent and cheap; defends against the
-- stale-cache failure mode that caused the May 11 lead-save bug chase.
NOTIFY pgrst, 'reload schema';

COMMIT;
