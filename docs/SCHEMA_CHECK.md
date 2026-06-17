# SCHEMA.md drift checker

`scripts/schema-check.js` keeps the mechanical parts of [`SCHEMA.md`](SCHEMA.md)
honest by regenerating them from the live Supabase catalog. It is a **local,
run-on-demand** tool. It is not wired to CI this round.

## What it does

It introspects the live Postgres catalog **read-only** and regenerates only the
regions of `SCHEMA.md` bounded by `<!-- AUTOGEN:... -->` markers:

- `table-count`  - the "N tables: A active + O orphan" sentence
- `table-inventory`  - the inventory grid (refreshes RLS + realtime flags)
- `columns:<table>`  - one column grid per table (name, type, carried Notes)
- `orphans`  - the orphan-table list

Everything outside the markers (translator notes, JSONB shapes, soft-FK
prose, the `admin_items` legacy-columns sub-table) is never touched.

Narrative cells are **carried forward by key**: a column's Notes / a table's
Purpose follow the row by name. New columns and tables are emitted with a
visible `<!-- NEW: fill in -->` flag for a human to complete.

It also doubles as an **RLS-posture monitor**: if any public table reports RLS
enabled, that is surfaced loudly (the v4.31 drift class), and it flags any table
that is in the DB but not the doc, or in the doc but not the DB.

## Setup

1. Copy `.env.example` to `.env` (gitignored) and set `DATABASE_URL` to the
   Supabase **session-pooler** URI (port 5432), found under Supabase Project
   Settings > Database > Connection string > Session pooler.
2. `npm install` (pulls in `pg`).

## Usage

```bash
npm run schema:check            # dry run: print the diff, exit nonzero if drifted. Writes nothing.
npm run schema:check -- --write # apply the regen to the marked regions of docs/SCHEMA.md
```

`schema:check` answers "is SCHEMA.md drifted?" safely (read-only, no file
write). `-- --write` fixes it. After a `--write`, review the diff, fill in any
`<!-- NEW: fill in -->` flags by hand, and commit.

Exit codes: `0` in sync (or after a successful `--write`), `1` drift detected in
`--check`, `2` setup/connection error (missing `DATABASE_URL`, unreachable DB).

## Read-only guarantees

- Every query runs inside an explicit `BEGIN; SET TRANSACTION READ ONLY; ...`
  so any write attempt throws at the database. The tool issues only
  SELECT/introspection - no DDL, DML, or NOTIFY.
- The only file it writes is `docs/SCHEMA.md`, only with `--write`, only between
  markers.
- `.env` is gitignored; the credential never enters the repo.

## Hardening: a dedicated `schema_reader` role (recommended, not required)

The default `DATABASE_URL` uses the privileged `postgres` credential. The
read-only transaction is the active safeguard, but the lowest-privilege option
is a dedicated login role. The checker reads **only** the catalog
(`information_schema` / `pg_catalog`, which are world-readable by default) and
never reads table data, so the role needs no data `SELECT` grants at all - just
the ability to log in:

```sql
-- Run once as an admin role in the Supabase SQL editor.
create role schema_reader with login password 'choose-a-strong-password';
-- No further grants needed: the checker only queries the catalog, which is
-- readable by PUBLIC. (If you later want the role to read table data too:
--   grant usage on schema public to schema_reader;
--   grant select on all tables in schema public to schema_reader; )
```

Then point `DATABASE_URL` at `schema_reader` instead of `postgres`. Not
provisioned this round, and the tool is not gated on it.
