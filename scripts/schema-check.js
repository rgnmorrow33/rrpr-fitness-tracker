#!/usr/bin/env node
/*
 * schema-check.js - SCHEMA.md drift checker
 *
 * Introspects the live Supabase Postgres catalog READ-ONLY and regenerates the
 * mechanical regions of docs/SCHEMA.md (the bits bounded by AUTOGEN markers):
 * the table-count sentence, the table inventory grid, one column grid per
 * table, and the orphan-table list. Narrative prose outside the markers is
 * never touched.
 *
 * Two modes:
 *   npm run schema:check              -> dry run. Prints a diff of what WOULD
 *                                        change and exits nonzero if drift
 *                                        exists. Writes NOTHING.
 *   npm run schema:check -- --write   -> applies the regen to the marked
 *                                        regions of docs/SCHEMA.md only.
 *
 * It also doubles as an RLS-posture monitor: if any public table reports RLS
 * ENABLED, that is surfaced LOUDLY regardless of mode (the v4.31 drift class),
 * and orphan detection flags any table that is in the DB but not the doc, or
 * in the doc but not the DB.
 *
 * HARD BOUNDARIES (by design):
 *   - READ-ONLY against the database. Every query runs inside an explicit
 *     BEGIN; SET TRANSACTION READ ONLY; ... COMMIT, so any write attempt throws
 *     at the DB. The tool issues SELECT/introspection only - no DDL, DML, NOTIFY.
 *   - The ONLY file it writes is docs/SCHEMA.md, and only in --write, and only
 *     between the AUTOGEN markers.
 *   - Local only. No CI, no GitHub Action this round.
 *
 * Connection:
 *   Reads DATABASE_URL from the environment. The npm script loads it from a
 *   local .env via Node's --env-file-if-exists. .env is gitignored; see
 *   .env.example for the session-pooler URI shape.
 *
 * Usage:
 *   npm run schema:check
 *   npm run schema:check -- --write
 *   node --env-file-if-exists=.env scripts/schema-check.js [--write]
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { Client } = require('pg');

const REPO_ROOT = path.resolve(__dirname, '..');
const SCHEMA_PATH = path.join(REPO_ROOT, 'docs', 'SCHEMA.md');

// Columns that live in the DB but are intentionally documented in a separate
// unmarked "Legacy / pre-cutover columns" sub-table, NOT the main AUTOGEN grid.
// Hand-maintained per the Phase 2 greenlight. Keys are table names; values are
// column names to EXCLUDE from the AUTOGEN:columns:<table> block.
const LEGACY_COLUMNS = {
  admin_items: ['trainer_name', 'description', 'category', 'approved'],
};

// format_type() spells some types out; the doc uses Postgres shorthand. Map the
// long forms to shorthand so an unchanged schema produces an empty diff. Unknown
// types pass through verbatim (uuid, jsonb, integer, boolean, numeric, date,
// text, text[] all already come back in the doc's preferred form).
const TYPE_MAP = {
  'timestamp with time zone': 'timestamptz',
  'timestamp without time zone': 'timestamp',
  'character varying': 'varchar',
};

function die(msg, code) {
  process.stderr.write(msg + '\n');
  process.exit(code == null ? 1 : code);
}

// ---------------------------------------------------------------------------
// Introspection queries (read-only). pg_catalog form chosen over
// information_schema.columns so format_type() yields clean names (text[], jsonb)
// where information_schema would report ARRAY / USER-DEFINED.
// ---------------------------------------------------------------------------
const Q_TABLES = `
  select table_name
  from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE'
  order by table_name;`;

const Q_COLUMNS = `
  select c.relname                            as table_name,
         a.attname                            as column_name,
         format_type(a.atttypid, a.atttypmod) as data_type,
         (not a.attnotnull)                   as is_nullable,
         a.attnum                             as ordinal
  from pg_attribute a
  join pg_class     c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and a.attnum > 0
    and not a.attisdropped
  order by c.relname, a.attnum;`;

const Q_RLS = `
  select c.relname        as table_name,
         c.relrowsecurity  as rls_enabled
  from pg_class     c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
  order by c.relname;`;

const Q_REALTIME = `
  select tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
  order by tablename;`;

async function introspect(connectionString) {
  const client = new Client({ connectionString });
  await client.connect();
  try {
    // Read-only transaction: belt-and-suspenders against any accidental write.
    await client.query('BEGIN');
    await client.query('SET TRANSACTION READ ONLY');
    const [tables, columns, rls, realtime] = await Promise.all([
      client.query(Q_TABLES),
      client.query(Q_COLUMNS),
      client.query(Q_RLS),
      client.query(Q_REALTIME),
    ]);
    await client.query('COMMIT');
    return {
      tables: tables.rows.map((r) => r.table_name),
      columns: columns.rows,
      rls: new Map(rls.rows.map((r) => [r.table_name, r.rls_enabled === true])),
      realtime: new Set(realtime.rows.map((r) => r.tablename)),
    };
  } finally {
    await client.end();
  }
}

function normType(t) {
  return TYPE_MAP[t] || t;
}

// ---------------------------------------------------------------------------
// Document parsing. We operate on the raw text and only rewrite between
// markers, so the surrounding narrative is preserved byte-for-byte.
// ---------------------------------------------------------------------------
function escRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Return the inner text between a marker pair, or null if the marker is absent.
function blockInner(text, name) {
  const re = new RegExp(
    '<!-- AUTOGEN:' + escRe(name) + ' START -->\\r?\\n([\\s\\S]*?)\\r?\\n<!-- AUTOGEN:' + escRe(name) + ' END -->'
  );
  const m = text.match(re);
  return m ? m[1] : null;
}

// Replace the inner text between a marker pair. Throws if the marker is absent
// (a missing marker is a doc-structure bug we want to fail loudly on).
function replaceBlock(text, name, newInner) {
  const re = new RegExp(
    '(<!-- AUTOGEN:' + escRe(name) + ' START -->\\r?\\n)[\\s\\S]*?(\\r?\\n<!-- AUTOGEN:' + escRe(name) + ' END -->)'
  );
  if (!re.test(text)) die('error: AUTOGEN marker pair "' + name + '" not found in docs/SCHEMA.md.', 1);
  return text.replace(re, (_all, start, end) => start + newInner + end);
}

// List the column-block table names present in the doc, in document order.
function columnsBlockTables(text) {
  const out = [];
  const re = /<!-- AUTOGEN:columns:([a-z_]+) START -->/g;
  let m;
  while ((m = re.exec(text))) out.push(m[1]);
  return out;
}

// Parse a markdown grid's data rows into arrays of trimmed cells. Skips the
// header row and the |---|---| separator. Assumes no literal pipes inside cells
// (true for this doc).
function parseRows(inner) {
  if (inner == null) return [];
  return inner
    .split(/\r?\n/)
    .filter((ln) => ln.trim().startsWith('|'))
    .map((ln) => ln.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim()))
    .filter((cells, i) => !(i === 0 || cells.every((c) => /^-*$/.test(c)))); // drop header + separator
}

function stripTicks(s) {
  return s.replace(/^`/, '').replace(/`$/, '');
}

// ---------------------------------------------------------------------------
// Section builders
// ---------------------------------------------------------------------------

// table-count: regenerate only when the numbers actually changed, so an
// in-sync doc keeps its existing hand-wrapped wording (empty diff). On drift,
// emit a single-line replacement carrying the corrected counts.
function buildTableCount(existingInner, counts) {
  const cur = existingInner && existingInner.match(/\*\*(\d+) tables\*\*[\s\S]*?(\d+) active[\s\S]*?(\d+) orphan/);
  if (cur && +cur[1] === counts.total && +cur[2] === counts.active && +cur[3] === counts.orphan) {
    return existingInner; // unchanged - preserve existing wording verbatim
  }
  return (
    'The `public` schema contains **' + counts.total + ' tables**: ' + counts.active +
    ' active tables wired to the codebase (listed below), plus ' + counts.orphan +
    ' orphan tables (empty, no code refs, no FK constraints) documented in the ' +
    '"Orphan tables" section following the per-table detail.'
  );
}

// table-inventory: preserve existing row order + Purpose + the Realtime channel
// annotation; refresh RLS and the Yes/No realtime flag from the live DB. Append
// any live non-orphan table missing from the inventory with a NEW Purpose flag.
function buildInventory(existingInner, db, orphanSet, newColFlag) {
  const existing = parseRows(existingInner); // [name, purpose, rls, realtime]
  const byName = new Map(existing.map((r) => [stripTicks(r[0]), r]));
  const order = existing.map((r) => stripTicks(r[0]));

  const liveNonOrphan = db.tables.filter((t) => !orphanSet.has(t));
  for (const t of liveNonOrphan) if (!byName.has(t)) order.push(t); // append new tables

  const lines = ['| Table | Purpose | RLS | Realtime |', '|---|---|---|---|'];
  for (const name of order) {
    const prev = byName.get(name);
    const live = db.tables.includes(name);
    const purpose = prev ? prev[1] : newColFlag;
    const rls = live ? (db.rls.get(name) ? 'Enabled' : 'Disabled') : (prev ? prev[2] : 'Disabled');
    const realtime = realtimeCell(name, prev ? prev[3] : null, db, live);
    lines.push('| `' + name + '` | ' + purpose + ' | ' + rls + ' | ' + realtime + ' |');
  }
  return lines.join('\n');
}

// Realtime cell: the publication tells us in/out (mechanical); the channel
// annotation in parens ("(app-changes)") is narrative we carry forward when the
// Yes/No polarity still agrees. Drift flips the flag and drops the stale paren.
function realtimeCell(name, prevCell, db, live) {
  if (!live) return prevCell || 'No';
  const inPub = db.realtime.has(name);
  if (inPub) {
    if (prevCell && /^Yes\b/.test(prevCell)) return prevCell; // keep "Yes (app-changes)"
    return 'Yes';
  }
  return 'No';
}

// columns:<table>: regenerate from live columns in ordinal order, excluding
// LEGACY_COLUMNS. Carry each column's Notes forward by name; flag new columns.
// Returns { inner, droppedDocCols } so the caller can warn about doc-only cols.
function buildColumns(table, existingInner, db, newColFlag) {
  const prev = parseRows(existingInner); // [name, type, notes]
  const prevNotes = new Map(prev.map((r) => [stripTicks(r[0]), r[2]]));
  const exclude = new Set(LEGACY_COLUMNS[table] || []);

  const liveCols = db.columns
    .filter((c) => c.table_name === table && !exclude.has(c.column_name))
    .sort((a, b) => a.ordinal - b.ordinal);
  const liveNames = new Set(liveCols.map((c) => c.column_name));

  const lines = ['| Column | Type | Notes |', '|---|---|---|'];
  for (const c of liveCols) {
    const notes = prevNotes.has(c.column_name) ? prevNotes.get(c.column_name) : newColFlag;
    const head = '| `' + c.column_name + '` | ' + normType(c.data_type) + ' |';
    // Match the doc's empty-cell style: "| type | |", not "| type |  |".
    lines.push(notes === '' ? head + ' |' : head + ' ' + notes + ' |');
  }
  const droppedDocCols = prev.map((r) => stripTicks(r[0])).filter((n) => !liveNames.has(n) && !exclude.has(n));
  return { inner: lines.join('\n'), droppedDocCols };
}

// orphans: carry forward existing orphan rows whose table still exists live;
// flag (and drop) ones that have vanished. Does not invent new orphan rows - a
// newly appeared live table surfaces via inventory + drift warnings instead.
function buildOrphans(existingInner, db) {
  const prev = parseRows(existingInner); // [name, notes]
  const lines = ['| Table | Notes |', '|---|---|'];
  const vanished = [];
  for (const r of prev) {
    const name = stripTicks(r[0]);
    if (db.tables.includes(name)) lines.push('| `' + name + '` | ' + r[1] + ' |');
    else vanished.push(name);
  }
  return { inner: lines.join('\n'), vanished, orphanNames: prev.map((r) => stripTicks(r[0])) };
}

// ---------------------------------------------------------------------------
// Diff rendering: write the proposed doc to a temp file and let git render a
// real unified diff. No diff-algorithm code to maintain, familiar output.
// ---------------------------------------------------------------------------
function renderDiff(currentText, proposedText) {
  const tmp = path.join(os.tmpdir(), 'schema-check-proposed-' + process.pid + '.md');
  fs.writeFileSync(tmp, proposedText);
  try {
    execFileSync('git', ['--no-pager', 'diff', '--no-index', '--no-color', '--', SCHEMA_PATH, tmp], {
      encoding: 'utf8',
    });
    return ''; // identical (git exits 0)
  } catch (e) {
    // git diff --no-index exits 1 when files differ; the diff text is on stdout.
    return e.stdout || '';
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) { /* best effort */ }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const write = process.argv.includes('--write');
  const NEW_FLAG = '<!-- NEW: fill in -->';

  const url = process.env.DATABASE_URL;
  if (!url) {
    die(
      'error: DATABASE_URL is not set.\n' +
      'Copy .env.example to .env and fill in the session-pooler URI, then re-run.\n' +
      '(.env is gitignored; the npm script loads it via --env-file-if-exists.)',
      2
    );
  }

  if (!fs.existsSync(SCHEMA_PATH)) die('error: docs/SCHEMA.md not found at ' + SCHEMA_PATH, 2);
  const currentText = fs.readFileSync(SCHEMA_PATH, 'utf8');
  const eol = currentText.includes('\r\n') ? '\r\n' : '\n';
  const joinEol = (s) => (eol === '\n' ? s : s.replace(/\n/g, eol));

  let db;
  try {
    db = await introspect(url);
  } catch (e) {
    die('error: could not introspect the database: ' + e.message + '\n' +
        '(check DATABASE_URL in .env - host, password, and that the project is reachable.)', 2);
  }

  // --- set arithmetic for orphan/drift detection ---
  const orphansParse = buildOrphans(blockInner(currentText, 'orphans'), db);
  const orphanSet = new Set(orphansParse.orphanNames);
  const docTables = new Set([
    ...columnsBlockTables(currentText), // active (have a column block)
    ...orphansParse.orphanNames,        // orphans
  ]);
  const inDbNotDoc = db.tables.filter((t) => !docTables.has(t));
  const inDocNotDb = [...docTables].filter((t) => !db.tables.includes(t));

  const total = db.tables.length;
  const orphan = orphansParse.orphanNames.filter((t) => db.tables.includes(t)).length;
  const countsResolved = { total, orphan, active: total - orphan };

  // --- build proposed document ---
  let proposed = currentText;
  proposed = replaceBlock(proposed, 'table-count', joinEol(buildTableCount(blockInner(proposed, 'table-count'), countsResolved)));
  proposed = replaceBlock(proposed, 'table-inventory', joinEol(buildInventory(blockInner(proposed, 'table-inventory'), db, orphanSet, NEW_FLAG)));
  proposed = replaceBlock(proposed, 'orphans', joinEol(orphansParse.inner));

  const droppedByTable = {};
  for (const table of columnsBlockTables(currentText)) {
    const built = buildColumns(table, blockInner(proposed, 'columns:' + table), db, NEW_FLAG);
    if (built.droppedDocCols.length) droppedByTable[table] = built.droppedDocCols;
    proposed = replaceBlock(proposed, 'columns:' + table, joinEol(built.inner));
  }

  const drifted = proposed !== currentText;

  // --- always-on report: RLS monitor + orphan/drift detection ---
  const out = [];
  const rlsEnabled = db.tables.filter((t) => db.rls.get(t) === true);
  if (rlsEnabled.length) {
    out.push('');
    out.push('################################################################');
    out.push('## RLS ENABLED on ' + rlsEnabled.length + ' public table(s): ' + rlsEnabled.join(', '));
    out.push('## The app has zero RLS-aware paths - enabled RLS will break');
    out.push('## reads/writes. This is the v4.31 drift class. Investigate now.');
    out.push('################################################################');
  } else {
    out.push('RLS posture: all ' + db.tables.length + ' public tables have RLS disabled (expected).');
  }

  if (inDbNotDoc.length) {
    out.push('');
    out.push('DRIFT - table(s) in the live DB but NOT documented in SCHEMA.md:');
    for (const t of inDbNotDoc) out.push('  + ' + t + '  (added to the inventory with a NEW flag; add a columns:' + t + ' marker block + per-table detail, or move it to the orphans list)');
  }
  if (inDocNotDb.length) {
    out.push('');
    out.push('DRIFT - table(s) documented in SCHEMA.md but NOT in the live DB:');
    for (const t of inDocNotDb) out.push('  - ' + t + '  (kept in the doc, not auto-removed; confirm it was dropped and remove its section by hand)');
  }
  if (orphansParse.vanished.length) {
    out.push('');
    out.push('Orphan table(s) listed in the doc but no longer live (dropped from the orphans block): ' + orphansParse.vanished.join(', '));
  }
  for (const [t, cols] of Object.entries(droppedByTable)) {
    out.push('');
    out.push('DRIFT - column(s) documented under `' + t + '` but absent from the live DB (removed from the grid): ' + cols.join(', '));
  }

  process.stdout.write(out.join('\n') + '\n');

  // --- mode-specific behavior ---
  const hardDrift = drifted || inDbNotDoc.length || inDocNotDb.length || rlsEnabled.length;

  if (write) {
    if (drifted) {
      fs.writeFileSync(SCHEMA_PATH, proposed);
      process.stdout.write('\nwrote docs/SCHEMA.md (regenerated marked regions).\n');
    } else {
      process.stdout.write('\ndocs/SCHEMA.md already up to date; nothing written.\n');
    }
    // --write exits 0 even on RLS/orphan warnings (they are surfaced loudly above).
    process.exit(0);
  }

  // --check (default): show the diff, exit nonzero on any drift.
  if (drifted) {
    process.stdout.write('\n=== proposed changes to docs/SCHEMA.md (run with -- --write to apply) ===\n');
    process.stdout.write(renderDiff(currentText, proposed));
  } else {
    process.stdout.write('\ndocs/SCHEMA.md mechanical sections are in sync with the live DB.\n');
  }
  process.exit(hardDrift ? 1 : 0);
}

if (require.main === module) {
  main().catch((e) => die('error: ' + (e && e.stack ? e.stack : e), 2));
}

module.exports = {
  normType,
  blockInner,
  replaceBlock,
  parseRows,
  buildColumns,
  buildInventory,
  buildOrphans,
  buildTableCount,
  LEGACY_COLUMNS,
};
