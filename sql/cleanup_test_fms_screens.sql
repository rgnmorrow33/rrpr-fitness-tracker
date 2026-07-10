-- Cleanup: remove throwaway test FMS screens from clients.assessments[]
-- Run in the Supabase SQL editor. SQL execution is Reagan's lane.
--
-- Context: all FMS screens saved during the v4.35-v4.38 module build were
-- test data. Carlos confirmed the ADR-0006 gates on 7/7/2026, so REAL
-- screens may exist after that date. Step 1 preview is mandatory - eyeball
-- every row before deleting anything.
--
-- What this touches:
--   - clients.assessments (removes entries with type = 'FMS' only;
--     any non-FMS assessment entries are preserved)
--   - clients.updated_at (stamped, consistent with app writes)
--
-- What this leaves alone:
--   - clients.pt_discharge (v4.39 workflow objects - separate signal,
--     NOT part of this cleanup)
--   - everything else on the row (sessions, packages, par_q, audit_log)
--
-- Carryforward from v4.7 (May 11): NOTIFY pgrst schema-cache reload at the
-- end to defend against the stale-cache class of bug.

-- ============================================================
-- STEP 1 - PREVIEW. Run this alone first. Do NOT skip.
-- ============================================================
-- Every FMS screen currently in the DB, one row per screen.
SELECT c.id            AS client_id,
       c.name          AS client_name,
       a->>'date'       AS screen_date,
       a->>'screened_by' AS screened_by,
       a->>'version'    AS fms_version,
       a->>'source'     AS source,
       (a->'composite'->>'total') AS composite_total
FROM clients c,
     jsonb_array_elements(c.assessments) a
WHERE a->>'type' = 'FMS'
ORDER BY a->>'date', c.name;

-- DECISION GATE:
--   * If every row is recognizably test data -> run Step 2A (delete all).
--   * If ANY row is a real screen (real client, real date, Carlos or a
--     trainer screening for real) -> do NOT run 2A. Use Step 2B with a
--     cutoff date instead, and confirm the cutoff against the preview.

-- ============================================================
-- STEP 2A - DELETE ALL FMS screens (only if preview is 100% test data)
-- ============================================================
BEGIN;

UPDATE clients
SET assessments = COALESCE(
      (SELECT jsonb_agg(a)
       FROM jsonb_array_elements(assessments) a
       WHERE a->>'type' IS DISTINCT FROM 'FMS'),
      '[]'::jsonb),
    updated_at = now()
WHERE assessments IS NOT NULL
  AND EXISTS (SELECT 1
              FROM jsonb_array_elements(assessments) a
              WHERE a->>'type' = 'FMS');

-- Refresh PostgREST schema cache (idempotent, cheap).
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- STEP 2B - DATE-BOUNDED DELETE (use instead of 2A if real screens exist)
-- ============================================================
-- Set the cutoff: screens ON OR BEFORE this date are deleted, screens
-- after it are kept. Confirm against the Step 1 preview before running.
--
-- BEGIN;
--
-- UPDATE clients
-- SET assessments = COALESCE(
--       (SELECT jsonb_agg(a)
--        FROM jsonb_array_elements(assessments) a
--        WHERE a->>'type' IS DISTINCT FROM 'FMS'
--           OR a->>'date' > '2026-07-06'),   -- <<< cutoff, adjust from preview
--       '[]'::jsonb),
--     updated_at = now()
-- WHERE assessments IS NOT NULL
--   AND EXISTS (SELECT 1
--               FROM jsonb_array_elements(assessments) a
--               WHERE a->>'type' = 'FMS'
--                 AND a->>'date' <= '2026-07-06');  -- <<< same cutoff
--
-- NOTIFY pgrst, 'reload schema';
--
-- COMMIT;

-- ============================================================
-- STEP 3 - VERIFY (run after 2A or 2B)
-- ============================================================
-- Expect zero rows after 2A; only the kept real screens after 2B.
-- SELECT c.name, a->>'date', a->>'screened_by'
-- FROM clients c, jsonb_array_elements(c.assessments) a
-- WHERE a->>'type' = 'FMS';
