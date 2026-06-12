# Migrations

Version-controlled SQL schema changes for the Round Rock Fitness Tracker
Supabase DB. Part of Phase 2B engineering hardening.

Before this folder existed, schema changes were run by hand in the Supabase
SQL editor and not tracked anywhere except the changelog prose. This folder
makes every DDL change a numbered, reviewable, idempotent file in the repo.

## How to run a migration

Reagan runs all SQL by hand in the Supabase SQL editor (no automated DB
access from CI). To apply a migration: open the file, copy the whole thing,
paste into the Supabase SQL editor, run. Every migration is wrapped in
`BEGIN; ... COMMIT;` so a mid-run failure rolls back cleanly.

Every migration ends with `NOTIFY pgrst, 'reload schema';` to refresh the
PostgREST schema cache. This defends against the stale-cache failure mode
that caused the May 11 lead-save bug chase (PGRST204). Do not remove it.

## Naming convention

```
NNNN_short_description.sql
```

- Four-digit zero-padded sequence prefix, starting at `0001`.
- Lowercase, underscore-separated description.
- Sequence is strictly increasing. Never renumber an applied migration.
- One logical change per file. Multiple related ALTERs for one feature can
  share a file; unrelated changes get separate files.

## Idempotency

Every migration must be safe to run more than once. Use:

- `CREATE TABLE IF NOT EXISTS`
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
- `CREATE INDEX IF NOT EXISTS`
- `DROP ... IF EXISTS`
- Guard data backfills with `WHERE` clauses that no-op on a second run.

The test: running an already-applied migration against production reports
zero changes and zero errors.

## The JSONB rule (read this before writing a migration)

**Most "schema changes" in this app are NOT DDL and do NOT get a migration
file.**

Per ADR-0004, `packages`, `sessions`, and `audit_log` are JSONB columns on
the `clients` row (and other entities follow the same JSONB-on-parent
pattern). Adding a field to any of those is a change to the JavaScript
constructor in `RoundRock_Fitness_Tracker.html` - the JSONB column accepts
whatever shape the constructor builds. **No SQL runs. No migration file.**

Examples that needed NO migration (they were JSONB key additions or app-side
data backfills, not DDL):

- `series_id` on `clients.sessions[]` (Sprint M)
- `package_id` on `clients.sessions[]` (Patch Z / v4.16)
- `participant_ids`, `package_size`, `primary_holder_id` on
  `clients.packages[]` (Phase 2A / v4.19)
- `dismissed_participant_candidates` (v4.20),
  `participants_at_creation` (v4.21)
- The v4.19 lazy participant backfill (ran in app code, not SQL)

A migration file is only needed for a true `CREATE TABLE`,
`ALTER TABLE ... ADD/DROP COLUMN`, index, or constraint change against a
real Postgres column. If you are about to write a migration for a field
that lives inside a JSONB column, stop - it belongs in the app code.

## Update the docs in the same change

When a migration adds or changes a real column, update `docs/SCHEMA.md` in
the same commit (or an immediately-following doc commit referencing the SQL).
The migration is the source of truth for what ran; SCHEMA.md is the
human-readable companion.

## Relationship to `/sql`

The existing `/sql` folder holds one-off operational scripts (e.g.
`wipe_pre_alpha_clients.sql`, a data-clearing script - not a schema change).
Those stay in `/sql`. `/migrations` is exclusively for schema DDL that
should be replayable to reconstruct the database structure.

---

## Files

### `0001_baseline.sql`

The retroactive capture of all schema changes run by hand up to 2026-06-12.
Generated from a live `information_schema` dump of production, not from
`docs/SCHEMA.md`. Idempotent: running it against the existing production DB
is a full no-op; running it against a fresh empty Supabase project recreates
the entire 17-table schema.

Covers 14 active tables + 3 orphan tables (see below). RLS is intentionally
not enabled (anon-RLS-open by design, per CLAUDE.md security posture).

---

## Known SCHEMA.md drift (surfaced by the baseline dump)

The live DB diverges from `docs/SCHEMA.md` in several places. `0001_baseline.sql`
captures **reality**; SCHEMA.md is the one that is wrong and needs a fix pass.
Logged here so the doc-fix is not lost. This is a documentation correction,
not a code or schema change - route the SCHEMA.md rewrite through web Claude
as a docs task.

- **`announcement_banners`**: real banner-text column is `body`, SCHEMA.md
  says `message`.
- **`classes`**: live table has duplicate/legacy column pairs not documented:
  `instructor_name` + `instructor`, and `start_time` + `time`. Also has a
  `cancellations` jsonb column SCHEMA.md omits entirely.
- **`clients`**: live `notes` and `is_active` columns are undocumented.
  `date_purchased` is `text` in the live DB, SCHEMA.md calls it `date`.
- **`closures`**: live `is_holiday` boolean is undocumented.
- **`leads`**: `status` default is `'new'`, SCHEMA.md implies `'waiting'`.
  `converted_at` is `text`, SCHEMA.md calls it `timestamptz`.
- **`member_contacts`**: live table has THREE overlapping text columns
  (`topic`, `note`, `notes`) plus both `logged_at` and `created_at`.
  SCHEMA.md documents a much cleaner shape than what exists.
- **`referrals`**: live table has NO `client_id` column, despite SCHEMA.md
  documenting a `clients.id` soft FK. Real columns: `referred_by`,
  `client_name`, `date`, `status` (default `'pending'`).
- **`settings`**: live shape is `uuid id` PK + `UNIQUE(key)`, with `value`
  as `text`. SCHEMA.md says `key` is the PK and `value` is `jsonb`.
- **`trainer_time_off`**: live table has a gap at ordinal position 14 (a
  dropped column). Current column set is captured in the baseline.

---

## Orphan tables (architectural decision pending - DO NOT drop in a backfill)

The dump revealed that the three "orphan" tables are **not empty stubs**.
They are fully-built normalized schemas with complete columns, defaults, and
primary keys. They appear to be an abandoned normalized data model that
predates the JSONB-on-clients decision (ADR-0004). All three hold zero rows
and have zero references in the app code.

- **`packages`**: a full normalized packages table (`package_type`,
  `total_sessions`, `purchase_date` as a real `date`, `trainer_id`,
  `valid_days_override`, soft-delete, audit_log). This is also where the
  `preferred_date` column actually lives - it was never on an active table.
- **`package_participants`**: a junction table with a composite
  `(package_id, client_id)` primary key and `joined_at`. Its shape matches
  the planned Phase 2C `client_package_participants` junction table. The
  name collision is already flagged in ADR-0002 Notes.
- **`queue`**: a full sub-coverage queue table (`class_id`, `requested_by`,
  `claimed_by`, `status` default `'open'`). The app's "queue" is a UI
  view-state string; this backing table is unused.

These are captured in `0001_baseline.sql` for fidelity. Their disposition -
drop them, or repurpose `package_participants` for the Phase 2C junction
table instead of building `client_package_participants` from scratch - is an
**architectural decision for web Claude**, tied to Phase 2C sequencing
(ADR-0002 / ADR-0003). A future `00NN_orphan_cleanup.sql` migration handles
it once that call is made. Do not drop them as part of routine work.

---

## Backlog (future cleanup migrations, not yet written)

Captured, not executed. Each becomes its own numbered migration when its
gating decision is made.

- **Orphan table disposition** (`packages`, `package_participants`, `queue`) -
  gated on the Phase 2C architectural call above.
- **`admin_items` legacy column drop** (`trainer_name`, `description`,
  `category`, `approved`) - inert pre-cutover columns, neither read nor
  written by current code. Low priority.
- **`classes` legacy column drop** (`instructor` vs `instructor_name`,
  `time` vs `start_time` duplicate pairs) - needs a code audit first to
  confirm which column in each pair is the live one before dropping the other.
- **`member_contacts` column consolidation** (`topic` / `note` / `notes`
  overlap, `logged_at` / `created_at` overlap) - needs a code audit to
  determine canonical columns.
- **APC `facility` value support** - when APC opens (April 2027), any
  `facility` CHECK constraint or enum will need `'APC'` added. No CHECK
  constraint exists on `closures.facility` today (it is a plain text column
  with a default), so this may be app-side only. Re-confirm before APC.
