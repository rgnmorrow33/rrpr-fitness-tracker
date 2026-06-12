-- =============================================================================
-- 0001_baseline.sql
-- Round Rock Fitness Tracker - schema baseline
-- =============================================================================
--
-- Generated 2026-06-12 from a live information_schema dump of the production
-- Supabase DB (project ofezaezijafglyjmisgz). This is the retroactive capture
-- of all schema changes run by hand in the Supabase SQL editor up to this date.
--
-- This file reflects the schema AS IT ACTUALLY EXISTS IN PRODUCTION, not as
-- documented in docs/SCHEMA.md. Where the two disagree, this file is correct
-- and SCHEMA.md has drift (see migrations/README.md "Known SCHEMA.md drift").
--
-- IDEMPOTENT. Safe to run against:
--   - a fresh/empty Supabase project (recreates the full schema), or
--   - the existing production DB (every statement is a no-op via IF NOT EXISTS).
--
-- Running this against production should report zero changes. That is the test
-- that this baseline matches reality.
--
-- RLS is intentionally NOT enabled here. The project runs anon-RLS-open by
-- design (see CLAUDE.md "Security posture"). Tightening RLS is tracked
-- separately and is out of scope for the baseline.
--
-- Column-default note: column defaults below mirror the live DB. Where the live
-- DB shows DEFAULT now()/gen_random_uuid()/etc, the app also sets these values
-- app-side; the DB default is the backstop, not the only writer.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- admin_items
-- Includes 4 legacy/pre-cutover columns (trainer_name, description, approved,
-- category) that current app code neither reads nor writes. Captured for
-- fidelity; cleanup is a future migration, not this one.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_items (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  trainer_name      text,
  date              text NOT NULL,
  hours             numeric NOT NULL DEFAULT 0,
  description       text,
  approved          boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  category          text,
  updated_at        timestamptz DEFAULT now(),
  source_session_id uuid,
  assignees         text[] DEFAULT ARRAY[]::text[],
  title             text,
  type              text,
  custom_type       text,
  time_in           text,
  time_out          text,
  note              text,
  created_by        text,
  CONSTRAINT admin_items_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- announcement_banners
-- Live banner-text column is `body` (NOT `message`, which SCHEMA.md claims).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS announcement_banners (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  body       text NOT NULL,
  starts_at  timestamptz NOT NULL DEFAULT now(),
  ends_at    timestamptz NOT NULL,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT announcement_banners_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- classes
-- Carries duplicate/legacy column pairs from a pre-cutover shape:
--   instructor_name + instructor, start_time + time.
-- Current code reads one of each pair; the other is inert. Captured as-is.
-- `cancellations` jsonb is real and undocumented in SCHEMA.md.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS classes (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  name                text NOT NULL,
  instructor_name     text,
  day_of_week         text,
  start_time          text,
  duration_minutes    integer,
  location            text,
  is_active           boolean NOT NULL DEFAULT true,
  attendance          jsonb NOT NULL DEFAULT '[]'::jsonb,
  cancellations       jsonb NOT NULL DEFAULT '[]'::jsonb,
  sub_assignments     jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  capacity            integer,
  season_start        text,
  season_end          text,
  time                text,
  instructor          text,
  room                text,
  class_type          text,
  is_premium          boolean DEFAULT false,
  end_time            text,
  schedule_version_id uuid,
  audit_log           jsonb DEFAULT '[]'::jsonb,
  deleted_at          timestamptz,
  deleted_by          text,
  created_by          text,
  CONSTRAINT classes_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- clients
-- The JSONB-heavy core table (packages, sessions, audit_log embedded).
-- `notes` and `is_active` are live and undocumented in SCHEMA.md.
-- `date_purchased` is text in the live DB (SCHEMA.md calls it date).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
  id                    uuid NOT NULL DEFAULT gen_random_uuid(),
  name                  text NOT NULL,
  trainer_name          text,
  packages              jsonb NOT NULL DEFAULT '[]'::jsonb,
  sessions              jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes                 text,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  email                 text,
  phone                 text,
  date_purchased        text,
  from_queue_id         uuid,
  location              text,
  membership_end        text,
  membership_type       text,
  membership_verified   boolean DEFAULT false,
  payment_type          text,
  team_member           text,
  referral_source       text,
  par_q                 jsonb DEFAULT '{}'::jsonb,
  last_package_added_at timestamptz,
  audit_log             jsonb DEFAULT '[]'::jsonb,
  deleted_at            timestamptz,
  deleted_by            text,
  created_by            text,
  CONSTRAINT clients_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- closures
-- `is_holiday` boolean is real and undocumented in SCHEMA.md.
-- `date` is text. `facility` defaults to 'all'.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS closures (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  date       text NOT NULL,
  reason     text,
  is_holiday boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  audit_log  jsonb DEFAULT '[]'::jsonb,
  deleted_at timestamptz,
  deleted_by text,
  facility   text NOT NULL DEFAULT 'all'::text,
  created_by text,
  CONSTRAINT closures_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- leads
-- `status` defaults to 'new' (SCHEMA.md implies 'waiting').
-- `converted_at` is text in the live DB.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
  id                     uuid NOT NULL DEFAULT gen_random_uuid(),
  name                   text NOT NULL,
  email                  text,
  phone                  text,
  source                 text,
  interest_area          text,
  status                 text NOT NULL DEFAULT 'new'::text,
  status_history         jsonb NOT NULL DEFAULT '[]'::jsonb,
  assigned_to            text,
  notes                  text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  consult_date           text,
  converted_at           text,
  converted_to_client_id uuid,
  source_tag             text,
  added_by               text,
  assigned_at            timestamptz,
  assigned_by            text,
  lost_reason            text,
  from_wro_id            uuid,
  audit_log              jsonb DEFAULT '[]'::jsonb,
  created_by             text,
  CONSTRAINT leads_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- member_contacts
-- Live table has THREE overlapping text columns: topic, note, notes.
-- Plus both logged_at and created_at. Drift from SCHEMA.md. Captured as-is.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS member_contacts (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  trainer_name text,
  date         text NOT NULL,
  type         text NOT NULL,
  topic        text,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz DEFAULT now(),
  logged_at    timestamptz,
  note         text,
  created_by   text,
  CONSTRAINT member_contacts_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- notifications
-- No updated_at column by design (translator avoids auto-stamping one).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  target_trainer_id uuid NOT NULL,
  type              text NOT NULL,
  payload           jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at           timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notifications_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- referrals
-- Live shape has NO client_id column (SCHEMA.md claims a client_id soft FK).
-- Real columns: referred_by, client_name, date, status. `status` defaults
-- to 'pending'.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS referrals (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  referred_by text,
  client_name text,
  date        text NOT NULL,
  notes       text,
  status      text DEFAULT 'pending'::text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz DEFAULT now(),
  created_by  text,
  CONSTRAINT referrals_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- schedule_versions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schedule_versions (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  label          text,
  created_by     text,
  data           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  effective_date text,
  is_active      boolean DEFAULT false,
  updated_at     timestamptz DEFAULT now(),
  deleted_at     timestamptz,
  deleted_by     text,
  CONSTRAINT schedule_versions_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- settings
-- Live shape: uuid id PK + UNIQUE(key). `value` is text (SCHEMA.md says jsonb).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS settings (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  key        text NOT NULL,
  value      text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settings_pkey PRIMARY KEY (id),
  CONSTRAINT settings_key_key UNIQUE (key)
);

-- -----------------------------------------------------------------------------
-- trainers
-- `role` and `role_tier` both present; role is the legacy column kept in sync.
-- UNIQUE(name) backs the upsert-by-name save pattern.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trainers (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  role           text NOT NULL DEFAULT 'trainer'::text,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz DEFAULT now(),
  previous_names jsonb DEFAULT '[]'::jsonb,
  pin            text,
  role_tier      text DEFAULT 'trainer'::text,
  audit_log      jsonb DEFAULT '[]'::jsonb,
  deleted_at     timestamptz,
  deleted_by     text,
  CONSTRAINT trainers_pkey PRIMARY KEY (id),
  CONSTRAINT trainers_name_unique UNIQUE (name)
);

-- -----------------------------------------------------------------------------
-- trainer_time_off
-- Live table has a gap at ordinal 14 (a dropped column). Current column set
-- captured below. `status` defaults to 'approved' (legacy rows auto-approve).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trainer_time_off (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  trainer_id    uuid NOT NULL,
  start_at      timestamptz NOT NULL,
  end_at        timestamptz NOT NULL,
  all_day       boolean DEFAULT false,
  kind          text NOT NULL,
  reason        text,
  created_by    text,
  audit_log     jsonb DEFAULT '[]'::jsonb,
  deleted_at    timestamptz,
  deleted_by    text,
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now(),
  status        text NOT NULL DEFAULT 'approved'::text,
  decided_by    text,
  decided_at    timestamptz,
  decision_note text,
  CONSTRAINT trainer_time_off_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- wros
-- JSONB-split: 5 flat columns + data jsonb.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wros (
  id             uuid NOT NULL DEFAULT gen_random_uuid(),
  trainer_name   text,
  client_name    text,
  date           text NOT NULL,
  notes          text,
  signature_data text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  data           jsonb DEFAULT '{}'::jsonb,
  updated_at     timestamptz DEFAULT now(),
  created_by     text,
  CONSTRAINT wros_pkey PRIMARY KEY (id)
);

-- =============================================================================
-- ORPHAN TABLES (abandoned normalized data model, predates ADR-0004)
-- =============================================================================
-- These three tables are fully-built normalized schemas the app NEVER wired
-- up. The live data model uses JSONB-on-clients instead (ADR-0004). They hold
-- zero rows and have zero code references.
--
-- They are captured here for baseline fidelity ONLY. The decision of whether to
-- drop them, or repurpose package_participants for the Phase 2C junction table
-- (it collides with the planned client_package_participants name - see ADR-0002
-- Notes), is an ARCHITECTURAL decision routed to web Claude. Do not drop in a
-- backfill. A future 00NN_orphan_cleanup migration handles disposition once the
-- Phase 2C call is made.
-- =============================================================================

-- packages: full normalized packages table. Holds preferred_date (the column
-- previously thought to be a stray ALTER on an active table - it lives here).
CREATE TABLE IF NOT EXISTS packages (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  template_id         text NOT NULL,
  facility            text NOT NULL,
  package_type        text NOT NULL,
  purchase_date       date NOT NULL,
  valid_days_override integer,
  total_sessions      integer NOT NULL,
  trainer_id          uuid,
  audit_log           jsonb DEFAULT '[]'::jsonb,
  deleted_at          timestamptz,
  deleted_by          text,
  created_at          timestamptz DEFAULT now(),
  created_by          text,
  preferred_date      timestamptz,
  CONSTRAINT packages_pkey PRIMARY KEY (id)
);

-- package_participants: junction table, composite PK. Shape matches the
-- planned Phase 2C client_package_participants. Name collision flagged in
-- ADR-0002 Notes - rename-vs-drop is the Phase 2C decision.
CREATE TABLE IF NOT EXISTS package_participants (
  package_id uuid NOT NULL,
  client_id  uuid NOT NULL,
  joined_at  timestamptz DEFAULT now(),
  CONSTRAINT package_participants_pkey PRIMARY KEY (package_id, client_id)
);

-- queue: sub-coverage queue table. The app's "queue" UI is a view-state
-- string; this backing table is unused (lead/consult queue lives in `leads`).
CREATE TABLE IF NOT EXISTS queue (
  id           uuid NOT NULL DEFAULT gen_random_uuid(),
  class_id     uuid,
  class_name   text,
  date         text NOT NULL,
  requested_by text,
  claimed_by   text,
  status       text NOT NULL DEFAULT 'open'::text,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text,
  CONSTRAINT queue_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- Refresh PostgREST schema cache. Idempotent and cheap. Defends against the
-- stale-cache failure mode that caused the May 11 lead-save bug chase.
-- -----------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';

COMMIT;
