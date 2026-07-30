-- ============================================================================
-- 0009_analytics_schema.sql
--
-- Read-only reporting views for quarterly business-plan numbers. The eight
-- in-app CSV exports are view-scoped UI tools, not extraction: they flatten
-- away packages[]/sessions[]/assessments[] and iterate the current UI filter
-- rather than the table. This migration adds a non-exposed `analytics`
-- schema of unnested views that reproduce the app's own math instead of
-- reinventing it.
--
-- SCOPE: read-only views only. No app code touched, no columns added to any
-- real table, nothing here is reachable by anon or authenticated.
--
-- ANON RE-ASSERTION (per CLAUDE.md Security posture, verified 2026-07-29):
-- before this migration, anon holds exactly ONE privilege in the entire
-- database: `public.trainer_directory:SELECT`. This migration does not
-- touch that grant and does not add anon/authenticated access anywhere.
-- Every view below is REVOKEd from anon and authenticated explicitly, the
-- schema itself is REVOKEd from PUBLIC, and default privileges on the
-- schema are locked down so a future `CREATE VIEW` in `analytics` cannot
-- silently inherit Supabase's ambient anon/authenticated grants the way
-- `trainer_directory` did before 0008 fixed it. Only `postgres` and
-- `service_role` can read these views - by design, this schema is a
-- reporting surface queried by hand in the Supabase SQL editor, not a
-- PostgREST-exposed API. `analytics` is not added to PostgREST's exposed-
-- schema list here (that list is a Supabase Dashboard project setting, not
-- repo state) - see the verification block for the manual dashboard check.
--
-- CORRECTIONS CARRIED IN FROM THE PHASE 1 DIAGNOSTIC (do not re-litigate):
--   - sessions[].package_id EXISTS at HEAD (Patch Z / v4.16). SCHEMA.md is
--     wrong claiming otherwise; SCHEMA.md is not fixed in this commit.
--   - Package price is STORED on the package row at purchase time, not
--     derived from type at read time. amountPaid is the authoritative
--     collected figure; price is the catalog list price at purchase.
--   - Fix D (v_class_occurrences) is CUT from this migration.
--
-- FIELD-NAME / TYPE GOTCHAS found while writing this migration (also not
-- fixed here - see PR description for the adjacent-smells list):
--   - SCHEMA.md's clients.sessions[] shape block lists `signature`/
--     `signedAt`/`clientSignedAt`/`recoveryLogged`/`recoveryDuration`/
--     `recoveryNote`. None of those are the real field names. The actual
--     write paths use `trainerSig`/`clientSig` (base64, no separate signed-
--     at timestamps exist) and a nested `serviceRecovery: {description,
--     durationHours, loggedBy, loggedAt}` object.
--   - clients.packages[]' shape block claims camelCase `deletedAt`/
--     `deletedBy`/`restoredAt`/`restoredBy`; the real write path
--     (softDeletePackage/restorePackage) uses snake_case `deleted_at`/
--     `deleted_by` and never stamps a restoration timestamp at all.
--   - uid() falls back to a non-UUID string ('id_' + random + timestamp)
--     on any browser without crypto.randomUUID. Every id sourced from a
--     JSONB array element (session id, package_id, series_id, primary_
--     holder_id) is therefore TEXT in these views, never cast to uuid -
--     a single legacy fallback-format row would otherwise abort the whole
--     view with a cast error.
-- Every JSONB field access below was verified against the actual
-- constructors (addSession, createRecurringSessions, addPackageToClient,
-- softDeletePackage, the bulk-import row builder), not against SCHEMA.md.
--
-- Idempotent: CREATE SCHEMA IF NOT EXISTS, CREATE OR REPLACE VIEW
-- throughout. Safe to run twice.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Fix A: schema + lockdown
-- ----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS analytics;

REVOKE ALL ON SCHEMA analytics FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA analytics TO postgres, service_role;

-- Mirrors the 0008 postmortem fix: without this, the NEXT view created in
-- `analytics` inherits Supabase's default anon/authenticated grants and
-- reopens exactly the trainer_directory hole.
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics REVOKE ALL ON TABLES FROM anon, authenticated, PUBLIC;

-- ----------------------------------------------------------------------------
-- Fix B (part 1): analytics.v_sessions
--
-- One row per session, unnested from clients.sessions[]. Foundational view -
-- v_packages and v_clients both read consumption_ratio from here rather
-- than re-deriving sessionConsumption's math, so there is exactly one SQL
-- copy of it, matching the app's own single sessionConsumption() function.
--
-- trainer_name is the CLIENT's assigned trainer (c.trainer_name), not the
-- sparse per-session `trainerName` field - that field is only ever stamped
-- by the recurring-series constructors (createRecurringSessions /
-- rescheduleSeriesFromHere); the primary one-off sign-off path (addSession)
-- never writes it. This matches calcTrainerHours' attribution, which also
-- keys off the client's trainer_name, not the session row.
--
-- consumption_ratio reproduces sessionConsumption() EXACTLY, including the
-- open BACKLOG defect: only status='excused' returns 0. 'scheduled' rows
-- deduct at the full duration ratio same as attended/no_show/late_cancel.
-- Reproduced intentionally, not corrected - see BACKLOG.md.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_sessions
WITH (security_invoker = true) AS
SELECT
  (sess.value->>'id')                                             AS session_id,
  c.id                                                              AS client_id,
  c.name                                                            AS client_name,
  c.trainer_name                                                    AS trainer_name,
  (sess.value->>'date')                                             AS session_date,
  (sess.value->>'time')                                             AS session_time,
  (sess.value->>'status')                                           AS status,
  NULLIF(sess.value->>'durationHours', '')::numeric                  AS duration_hours,
  NULLIF(sess.value->>'package_id', '')                              AS package_id,
  NULLIF(sess.value->>'series_id', '')                               AS series_id,
  (sess.value->>'trainerSig') IS NOT NULL                            AS has_trainer_signature,
  (sess.value->>'clientSig') IS NOT NULL                             AS has_client_signature,
  (sess.value->'serviceRecovery'->>'description')                    AS recovery_description,
  NULLIF(sess.value->'serviceRecovery'->>'durationHours', '')::numeric AS recovery_duration_hours,
  (sess.value->'serviceRecovery'->>'loggedBy')                       AS recovery_logged_by,
  NULLIF(sess.value->'serviceRecovery'->>'loggedAt', '')::timestamptz AS recovery_logged_at,
  CASE
    WHEN sess.value->>'status' = 'excused' THEN 0
    WHEN NULLIF(sess.value->>'durationHours', '')::numeric = 0.5 THEN 0.5
    ELSE 1  -- durationRatio's own default: null/1/any-other-numeric all deduct 1.0
  END                                                                 AS consumption_ratio,
  c.deleted_at IS NOT NULL                                           AS client_is_deleted
FROM public.clients c
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.sessions, '[]'::jsonb)) AS sess(value);

REVOKE ALL ON analytics.v_sessions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON analytics.v_sessions TO postgres, service_role;

-- ----------------------------------------------------------------------------
-- Fix B (part 2): analytics.v_packages
--
-- One row per package, unnested from clients.packages[]. is_pairs/is_consult/
-- is_intro/location/valid-days precedence are catalog-resolved: verified
-- against every package constructor in the app (NewClientModal's initial
-- package, AddPackageModal/re-up, the bulk RecTrac CSV importer) and NONE
-- of them stamp is_pairs/is_consult/is_intro/location/validDays onto the
-- package row - those are resolved live via resolvePackageTemplate(pkg),
-- which matches by template_id first, then by type, across both facility
-- catalogs. pt_catalog below is a point-in-time mirror of
-- PT_PACKAGES_BY_FACILITY (v4.52). If that JS catalog changes, this mirror
-- goes stale until manually resynced - flagged, not solved, here.
--
-- package_key is this view's own stable identity (client_id + array
-- position). Most packages never receive a real `id` at all - none of the
-- three constructors above stamp one; the app only backfills one lazily,
-- via a narrow useEffect, the moment a client's sign-off picker needs to
-- disambiguate 2+ simultaneously-active packages. package_id (nullable,
-- text - see uid() note above) passes through the raw stored id for
-- joining against v_sessions.package_id when it exists.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_packages
WITH (security_invoker = true) AS
WITH pt_catalog(cat_id, cat_type, cat_location, cat_valid_days, cat_is_pairs, cat_is_consult, cat_is_intro) AS (
  VALUES
    ('cmrc-consult',    'CMRC-Consult',   'CMRC', NULL::int, false, true,  false),
    ('cmrc-pt-1',       'CMRC-PT-1',      'CMRC', 365,       false, false, false),
    ('cmrc-pt-3',       'CMRC-PT-3',      'CMRC', 365,       false, false, false),
    ('cmrc-pt-5',       'CMRC-PT-5',      'CMRC', 365,       false, false, false),
    ('cmrc-pt-10',      'CMRC-PT-10',     'CMRC', 365,       false, false, false),
    ('cmrc-pt-15',      'CMRC-PT-15',     'CMRC', 365,       false, false, false),
    ('cmrc-pt-20',      'CMRC-PT-20',     'CMRC', 365,       false, false, false),
    ('cmrc-pairs-4',    'CMRC-Pairs-4',   'CMRC', 365,       true,  false, false),
    ('cmrc-pairs-8',    'CMRC-Pairs-8',   'CMRC', 365,       true,  false, false),
    ('cmrc-pairs-12',   'CMRC-Pairs-12',  'CMRC', 365,       true,  false, false),
    ('baca-consult',    'Baca-Consult',   'Baca', NULL,      false, true,  false),
    ('baca-1sttime-3',  'Baca-1stTime-3', 'Baca', 365,       false, false, true),
    ('baca-pt-3',       'Baca-PT-3',      'Baca', 365,       false, false, false),
    ('baca-pt-5',       'Baca-PT-5',      'Baca', 365,       false, false, false),
    ('baca-pt-10',      'Baca-PT-10',     'Baca', 365,       false, false, false),
    ('baca-pt-15',      'Baca-PT-15',     'Baca', 365,       false, false, false),
    ('baca-pt-20',      'Baca-PT-20',     'Baca', 365,       false, false, false),
    ('baca-pairs-4',    'Baca-Pairs-4',   'Baca', 30,        true,  false, false),
    ('baca-pairs-8',    'Baca-Pairs-8',   'Baca', 60,        true,  false, false)
),
client_packages AS (
  SELECT
    c.id AS client_id, c.name AS client_name,
    pkg.ordinality AS pkg_ord, pkg.value AS pkg,
    NULLIF(pkg.value->>'id', '') AS pkg_id,
    pkg.value->>'deleted_at' AS pkg_deleted_at_raw
  FROM public.clients c
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.packages, '[]'::jsonb)) WITH ORDINALITY AS pkg(value, ordinality)
),
active_fifo AS (
  -- FIFO rank among this client's ACTIVE (non-deleted) packages only,
  -- mirroring fifoComparator: purchaseDate then array position. Packages
  -- never carry their own createdAt, so fifoComparator's createdAt tier
  -- never actually fires in practice - purchaseDate + position is real.
  SELECT client_id, pkg_ord,
    ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY (pkg->>'purchaseDate') NULLS LAST, pkg_ord) AS fifo_rank
  FROM client_packages
  WHERE pkg_deleted_at_raw IS NULL
)
SELECT
  cp.client_id, cp.client_name,
  cp.client_id::text || ':' || cp.pkg_ord                          AS package_key,
  cp.pkg_id                                                         AS package_id,
  (cp.pkg->>'type')                                                 AS type,
  (cp.pkg->>'template_id')                                          AS template_id,
  COALESCE(cp.pkg->>'location', resolved.cat_location)              AS location,
  NULLIF(cp.pkg->>'sessions', '')::int                              AS sessions_purchased,
  NULLIF(cp.pkg->>'price', '')::numeric                             AS price,
  NULLIF(cp.pkg->>'amountPaid', '')::numeric                        AS amount_paid,
  NULLIF(cp.pkg->>'purchaseDate', '')::date                         AS purchase_date,
  (cp.pkg->>'paymentType')                                          AS payment_type,
  (cp.pkg->>'source')                                                AS source,
  COALESCE((cp.pkg->>'is_pairs')::boolean, resolved.cat_is_pairs)    AS is_pairs,
  COALESCE((cp.pkg->>'is_consult')::boolean, resolved.cat_is_consult) AS is_consult,
  COALESCE((cp.pkg->>'is_intro')::boolean, resolved.cat_is_intro)    AS is_intro,
  (cp.pkg->'participant_ids')                                        AS participant_ids,
  NULLIF(cp.pkg->>'package_size', '')::int                          AS package_size,
  NULLIF(cp.pkg->>'primary_holder_id', '')                          AS primary_holder_id,
  NULLIF(cp.pkg->>'participants_at_creation', '')::int              AS participants_at_creation,
  cp.pkg_deleted_at_raw IS NOT NULL                                  AS is_deleted,
  NULLIF(cp.pkg_deleted_at_raw, '')::timestamptz                     AS deleted_at,
  -- packageValidDays precedence: validDaysOverride, then validDays, then
  -- catalog. NULL means "no expiry resolvable" (consult rows, rows whose
  -- type/template_id matches nothing in the catalog) - not zero.
  COALESCE(
    NULLIF(cp.pkg->>'validDaysOverride', '')::int,
    NULLIF(cp.pkg->>'validDays', '')::int,
    resolved.cat_valid_days
  )                                                                  AS resolved_valid_days,
  NULLIF(cp.pkg->>'purchaseDate', '')::date + COALESCE(
    NULLIF(cp.pkg->>'validDaysOverride', '')::int,
    NULLIF(cp.pkg->>'validDays', '')::int,
    resolved.cat_valid_days
  )                                                                  AS expires_on,
  COALESCE(NULLIF(cp.pkg->>'consumedBeforeImport', '')::numeric, 0)  AS consumed_before_import,
  -- sessions_consumed / _excl_scheduled: sessionsRemainingFromPackage's
  -- attribution model, one LATERAL pass with two FILTERed sums instead of
  -- two separate correlated subqueries. A session attributes here if its
  -- package_id matches this package's own id, OR (package_id is null AND
  -- this package is the FIFO-earliest ACTIVE package for the client) - the
  -- null-package_id fallback a plain GROUP BY package_id would silently
  -- drop. sessions_consumed includes 'scheduled' sessions (the open
  -- BACKLOG defect, reproduced not corrected); _excl_scheduled is the
  -- measure of what it would be if that defect were fixed.
  consumed.all_statuses                                              AS sessions_consumed,
  consumed.excl_scheduled                                            AS sessions_consumed_excl_scheduled
FROM client_packages cp
LEFT JOIN LATERAL (
  SELECT * FROM pt_catalog cat
  WHERE cat.cat_id = COALESCE(cp.pkg->>'template_id', '') OR cat.cat_type = COALESCE(cp.pkg->>'type', '')
  ORDER BY (cat.cat_id = cp.pkg->>'template_id') DESC
  LIMIT 1
) resolved ON true
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(vs.consumption_ratio), 0)                                              AS all_statuses,
    COALESCE(SUM(vs.consumption_ratio) FILTER (WHERE vs.status <> 'scheduled'), 0)       AS excl_scheduled
  FROM analytics.v_sessions vs
  LEFT JOIN active_fifo af ON af.client_id = vs.client_id AND af.pkg_ord = cp.pkg_ord
  WHERE vs.client_id = cp.client_id
    AND ((vs.package_id IS NOT NULL AND vs.package_id = cp.pkg_id)
         OR (vs.package_id IS NULL AND af.fifo_rank = 1))
) consumed ON true;

COMMENT ON VIEW analytics.v_packages IS
  'Per-package remaining (sessions_purchased - sessions_consumed - consumed_before_import) uses the FIFO/package_id attribution model. This is a DIFFERENT attribution model from v_clients.sessions_remaining, which is client-wide and ignores package_id entirely. Summing this view''s per-package remaining across a client is not expected to equal v_clients.sessions_remaining for that client in every case - both are faithful to the app, which computes them two different ways in two different helpers (sessionsRemainingFromPackage vs sessionsRemaining).';

REVOKE ALL ON analytics.v_packages FROM PUBLIC, anon, authenticated;
GRANT SELECT ON analytics.v_packages TO postgres, service_role;

-- ----------------------------------------------------------------------------
-- Fix C (part 1): analytics.v_clients
--
-- Three independent "recency" calculations coexist in the app today
-- (Phase 1 finding): lastActivityDate, clientPackageFlags' inline calc, and
-- lastSeenDate/daysSinceLastSeen. Per Reagan's direction, this view emits
-- the two that back real on-screen numbers and documents, but does not
-- emit, the third:
--   - days_since_last_activity mirrors lastActivityDate (status-filtered to
--     attended/late_cancel/no_show/excused, excludes 'scheduled'; createdAt
--     is a last resort only, per the v4.51 fix - never a max participant).
--     Basis for clientLifecycleStatus (dormant/lapsed/active).
--   - days_since_last_seen_app mirrors lastSeenDate/daysSinceLastSeen (NO
--     status filter - a scheduled or future-dated session still counts;
--     falls back to date_purchased, never createdAt, when no sessions
--     exist at all). Exact calc that drives the on-screen isClientCold /
--     churn-risk flag.
--   - NOT emitted: clientPackageFlags' inline "days since" (renewal chip).
--     It differs from both above (no status filter like lastSeenDate, but
--     a createdAt fallback like lastActivityDate) and the app's own
--     comments call it a future migration target, not yet unified with
--     lastActivityDate. A third recency column here would be a fourth
--     answer to the same question - documented, not built.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_clients
WITH (security_invoker = true) AS
SELECT
  c.id AS client_id, c.name AS client_name, c.created_at, c.trainer_name,
  c.phone, c.email, c.location, c.is_active, c.deleted_at,
  (SELECT count(*) FROM analytics.v_sessions vs WHERE vs.client_id = c.id) AS lifetime_session_count,
  -- Client-wide remaining: sessionsRemaining's model, ignores package_id.
  GREATEST(0,
    COALESCE((SELECT SUM(vp.sessions_purchased) FROM analytics.v_packages vp WHERE vp.client_id = c.id AND NOT vp.is_deleted), 0)
    - COALESCE((SELECT SUM(vs.consumption_ratio) FROM analytics.v_sessions vs WHERE vs.client_id = c.id), 0)
    - COALESCE((SELECT SUM(vp.consumed_before_import) FROM analytics.v_packages vp WHERE vp.client_id = c.id AND NOT vp.is_deleted), 0)
  )                                                                  AS sessions_remaining,
  (CURRENT_DATE - COALESCE(
    (SELECT max(vs.session_date)::date FROM analytics.v_sessions vs
       WHERE vs.client_id = c.id AND vs.status IN ('attended','late_cancel','no_show','excused')),
    (SELECT max(vp.purchase_date) FROM analytics.v_packages vp WHERE vp.client_id = c.id AND NOT vp.is_deleted),
    c.created_at::date
  ))                                                                 AS days_since_last_activity,
  (CURRENT_DATE - COALESCE(
    (SELECT max(vs.session_date)::date FROM analytics.v_sessions vs WHERE vs.client_id = c.id),
    c.date_purchased::date
  ))                                                                 AS days_since_last_seen_app,
  -- Catches both PT-discharge signals Phase 1 found: the dedicated
  -- pt_discharge column, and an FMS assessment logged with
  -- source='post_pt_discharge'. Mirrors hasDischargeAssessment exactly.
  (
    c.pt_discharge IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(COALESCE(c.assessments, '[]'::jsonb)) AS a(value)
      WHERE a.value->>'source' = 'post_pt_discharge'
    )
  )                                                                  AS pt_discharge_origin
FROM public.clients c;

REVOKE ALL ON analytics.v_clients FROM PUBLIC, anon, authenticated;
GRANT SELECT ON analytics.v_clients TO postgres, service_role;

-- ----------------------------------------------------------------------------
-- Fix C (part 2): analytics.v_leads
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_leads
WITH (security_invoker = true) AS
SELECT
  l.id AS lead_id, l.name AS lead_name, l.email, l.phone, l.source, l.interest_area,
  l.status, l.assigned_to, l.notes, l.created_at, l.updated_at, l.consult_date,
  l.converted_at, l.converted_to_client_id, l.source_tag, l.lost_reason,
  latest.value                AS latest_status_history
FROM public.leads l
LEFT JOIN LATERAL (
  SELECT value FROM jsonb_array_elements(COALESCE(l.status_history, '[]'::jsonb)) AS h(value)
  ORDER BY (value->>'ts') DESC NULLS LAST
  LIMIT 1
) latest ON true;

REVOKE ALL ON analytics.v_leads FROM PUBLIC, anon, authenticated;
GRANT SELECT ON analytics.v_leads TO postgres, service_role;

-- ----------------------------------------------------------------------------
-- Self-test: analytics schema is unreachable by anon/authenticated, and the
-- pre-existing public-schema anon posture (CLAUDE.md Security posture) is
-- unchanged by this migration.
-- ----------------------------------------------------------------------------

DO $$
DECLARE n_analytics_grants int; n_public_anon int;
BEGIN
  SELECT count(*) INTO n_analytics_grants
  FROM information_schema.table_privileges
  WHERE table_schema = 'analytics' AND grantee IN ('anon', 'authenticated');
  IF n_analytics_grants > 0 THEN
    RAISE EXCEPTION 'ABORT: anon/authenticated hold % grant(s) on analytics views.', n_analytics_grants;
  END IF;

  IF has_schema_privilege('anon', 'analytics', 'USAGE') THEN
    RAISE EXCEPTION 'ABORT: anon has USAGE on schema analytics.';
  END IF;
  IF has_schema_privilege('authenticated', 'analytics', 'USAGE') THEN
    RAISE EXCEPTION 'ABORT: authenticated has USAGE on schema analytics.';
  END IF;

  SELECT count(*) INTO n_public_anon
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public' AND grantee = 'anon';
  IF n_public_anon <> 1 THEN
    RAISE EXCEPTION 'ABORT: anon privilege count in public is % (expected exactly 1: trainer_directory SELECT). This migration should not have touched public grants.', n_public_anon;
  END IF;

  RAISE NOTICE 'analytics schema is unreachable by anon/authenticated (0 grants); public anon posture unchanged (1 privilege: trainer_directory:SELECT).';
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================================
-- STANDING CHECK. Run after any future migration touching the analytics
-- schema:
--
--   select table_schema, table_name, grantee, privilege_type
--   from information_schema.table_privileges
--   where table_schema = 'analytics' and grantee in ('anon','authenticated');
--
--   -> expected: zero rows.
-- ============================================================================
