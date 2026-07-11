# Round Rock Parks and Recreation - Fitness Tracker Update Log

**Current version: v4.45**

Newest version at the top; append new sections above the older ones.

> Canonical running log, now version-controlled in `docs/`. It previously lived
> only as a Word doc outside git and drifted (a stale v4.29 copy caused
> confusion on July 10). Keep it here going forward. `npm run log:scaffold`
> produces the raw material (SHAs, diff stats, file lists) for new entries.

---

## Current standing - audited July 10, 2026

- **Live version: v4.45**, tagged and pushed; Netlify prod (pardfitnesstracker2)
  auto-deployed. Tracker file: 30,966 lines / 1.32 MB. `node --check` on the
  embedded JS at HEAD: PASS.
- Everything is pushed - local `main` equals `origin/main`. The only local-only
  work is Reagan's in-progress Playwright local-test files (untracked) and
  matching `package.json` script edits.
- **[Resolved]** The two previously-unversioned features - sessions_low renewal
  alerts (`51be225`) and persist-then-toast infrastructure Batch A (`31ca2d6`) -
  are now documented under the v4.43 window (see that entry). Tags kept as-is
  per decision; not retro-tagged. v4.44 / v4.45 are the two new features below.
- **Two live import pipelines now auto-write to prod through the public anon
  key, on scheduled Windows tasks:**
  - **Intake** - Forms -> Power Automate -> OneDrive dropbox -> `intake_import.py`,
    5am daily. As of v4.44 it creates a client AND a linked `waiting`
    consult-queue lead; the full packet renders on the lead in LeadDetailModal.
  - **Purchase** - RecTrac Training Packages Report CSV -> OneDrive drop folder
    -> `purchase_import.py`, 8am weekdays. Attaches packages to matched clients
    and creates client rows for unmatched buyers (backfill).
- **RLS on the clients/leads tables is URGENT (escalated further).** Two
  importers now auto-write through the committed anon key: intake writes
  health-screening PHI (client + lead), purchase writes package/financial data
  and auto-creates client rows. Public-anon-key writes of PHI and auto-created
  records is not the right posture for live data. This was acceptable-for-
  prototype before any of this data existed; it is not now.
- **Paper-trail drift:** `intake-import/README.md` still documents the retired
  no-write posture; `purchase-import/` has no README; NO ADR captures either
  auto-write pipeline. CLAUDE.md's realtime section still says 2 published
  tables (June 17) versus the 5 verified July 9.
- **Credential hygiene:** a Supabase key was pasted into a working chat during
  setup on July 10 - rotate it. The scheduled tasks correctly use the
  designed-public anon key (RLS disabled, so it authorizes the writes).
- SCHEMA.md autogen regions are missing the `pt_discharge` and
  `intake_paperwork` columns - run `npm run schema:check -- --write` against the
  live DB. (Note: `leads` has no `intake_paperwork` column by design - the
  packet stays on the client and renders on the lead via `fromQueueId`.)
- Test-FMS cleanup SQL (`4cb4a1a`) is committed and preview-gated but has not
  been run against the database.

---

## v4.45 - July 10, 2026

Automates PT-package population onto client profiles from RecTrac purchases, and
fills two catalog gaps. RecTrac already emails a daily "Training Packages Report"
and drops the CSV into a synced OneDrive folder; a new importer reads it and
attaches each purchase as a package on the matching client.

### Trigger
Packages were entered by hand. The RecTrac Training Packages Report (with
email/phone, package, dates, transaction type) was already landing in a local
OneDrive folder daily - an unused feed ready to drive package population.

### Goal
Purchases land as packages on the right client automatically, with no manual
entry, and new buyers who never did an intake still get a client record.

### File version
v4.45 - 30,966 lines, 1.32 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **`purchase-import/purchase_import.py`** (new) - reads the report CSV, maps
  each `pt_package` to a canonical type (exact map + pattern fallback that
  handles Baca zero-padding `03` and the `1st Time` intro), matches the buyer by
  email then phone, and PATCHes the package onto `client.packages` - or CREATEs
  the client from the row when there is no match. Idempotent by
  `(type, purchaseDate)` so re-running the daily/YTD report never double-adds.
  `Purchase -> rectrac_import`, `Renewal -> rectrac_reup`; `validDays` derived
  from the CSV's start/expiry. `--dry-run` is zero-write.
- **CMRC-Pairs-8 ($105) and CMRC-Pairs-12 ($145)** added to
  `PT_PACKAGES_BY_FACILITY` - both sold in RecTrac (confirmed in the YTD report)
  but were missing from the app catalog, so the importer could not map them.
- **Scheduled task "RRPR Purchase Import"** - 8am weekdays (after the ~7am
  report drop, so it processes same-day). Local wrapper + log gitignored.

### Test results
- `node --check` on the embedded JS - PASS
- `py_compile` on the importer - PASS
- Product-name mapper unit-tested against every live report name - PASS
- Dry-run then LIVE run against the real backlog verified: Tom Blaney's CMRC-PT-20
  appended alongside his existing package, Joy Brack created with CMRC-Pairs-12,
  Jayashree Ramanathan created with CMRC-PT-10; duplicate rows skipped
- Tagged v4.45 before push per tag-on-release

### Deferred
- RLS (see Current standing) - now doubly urgent with a second auto-write path
- README + ADR for the purchase importer's auto-write posture
- Rotate the Supabase key pasted into chat during setup

---

## v4.44 - July 10, 2026

Turns the intake into a pickable consult and puts the full packet in front of
the trainer. Each validated intake now provisions a client AND a linked
`waiting` lead in the consult queue; the same read-only packet render is shared
so it appears on the lead a trainer picks up, not just on the client.

### Trigger
The intake render (v4.43) only showed on a client, but a trainer working a
consult is looking at a lead, not a client yet - so the paperwork was invisible
at the moment it is most useful, and intakes did not feed the consult queue.

### Goal
A trainer picks up an intake as a consult lead and reads the whole
screening / goals / history inline; the intake feeds the consult queue the way
the architecture always intended.

### File version
v4.44 - 30,961 lines, 1.32 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Shared `IntakePaperworkSection` helper** - the ClientDetail packet render was
  extracted into a reusable, definition-driven (`INTAKE_SECTIONS`) function so
  ClientDetail and the consult queue render an identical packet.
- **LeadDetailModal renders the packet** from the lead's linked prospect client
  (`client.fromQueueId === lead.id`, read from `ctx.allClients`) - single source
  of truth, no `leads.intake_paperwork` column needed.
- **`ms_forms` added to `QUEUE_SOURCE_LABEL`** ("Microsoft Forms intake").
- **`intake_import.py`** now provisions both records: a client with
  `intake_paperwork` and a linked `waiting` lead (`source ms_forms`), wiring
  `client.from_queue_id = lead.id`. Dedup: existing client -> PATCH paperwork and
  add a lead only if none is open; new person -> create client, reuse an open
  lead or make one; junk -> review. Existing conversion machinery flips the lead
  to converted on first session log.

### Test results
- `node --check` on the embedded JS - PASS
- `py_compile` on the importer - PASS
- Dry-run then LIVE run verified: a lead was created for a re-dropped test
  intake, its linked client's `from_queue_id` points back to it, and the packet
  renders through the lead -> linked-client -> INTAKE_SECTIONS path
- Tagged v4.44 before push per tag-on-release

### Deferred
- RLS (see Current standing) - the intake path now also writes a lead per submit
- README/ADR update: the intake importer's no-write README is retired posture

---

## v4.43 - July 10, 2026

Locks the Intake Paperwork render to the real Pre-Assessment form. The live
Microsoft Forms export showed the assumed v4.40 shape had drifted in every
section, so intake-v2 replaces it field-by-field. Screening yes answers surface
as amber flags with a count chip, and a latent Yes/No string bug is fixed.
Shipped alongside (separate commits, not tracker versions): the intake-import
dropbox processor, later upgraded the same day to auto-create clients (`d19f7c3`).

### Trigger
Live Forms export of the CMRC Adult Fitness Pre-Assessment Packet (8 test
responses) surfaced shape drift against the assumed intake-v1 keys from v4.40.

### Goal
ClientDetail shows exactly what the member submitted, with screening flags
readable at a glance before a trainer ever meets the client.

### File version
v4.43 - 30,948 lines, 1.38 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **intake-v2 shape locked** - INTAKE_SECTIONS rebuilt field-by-field against the
  export: Participant (adds facility, consent), Health Screening (11 yes/no
  screens + surgery detail + details + medications), Exercise History (6
  free-text), Goals (short/long term), Lifestyle (nutrition, meals, sleep,
  stress, nicotine, alcohol). No production rows carried intake-v1, so no
  back-compat guard.
- **New `flag` field type** - screening yes/no where YES is the clinical finding.
  Renders amber instead of moss, distinct from neutral bool fields (consent,
  alcohol).
- **Screening flags header chip** - amber "N SCREENING FLAGS" chip counting yes
  answers across flag fields. Same semantics as the PAR-Q flag count in
  NewClientModal.
- **Yes/No coercion bug fix** - Forms sends "Yes"/"No" strings; the v4.40
  truthiness check would render "No" as a Yes pill. Both pill types now coerce
  through `intakeBool()`; empty string reads as unanswered and the row is skipped.

### Previously unversioned - folded into this window
Two app features shipped in the v4.43 window (ancestors of the v4.43 tag) without
their own version number; documented here rather than retro-tagged (tags kept
as-is):
- **sessions_low renewal alerts** (`51be225`) - low-session renewal alerts driven
  off the package_expiring sweep.
- **persist-then-toast infrastructure Batch A** (`31ca2d6`) - Patch G2 persist-
  then-toast scaffolding, no callers wired yet.

### Test results
- `node --check` on the embedded JS - PASS
- Single commit +90/-38, tagged v4.43 before push per tag-on-release
- `intake_import.py` offline tests exercise the same shape: normalize (Yes/No to
  booleans, M/D/YYYY to ISO, empty-string drop), match lanes, dollar-quoted JSONB
  with apostrophes - PASS

### Deferred
- RLS decision on the clients table - escalated to urgent by the same-day
  auto-write posture change (see Current standing)
- SCHEMA.md autogen refresh after the intake_paperwork column - also picks up the
  undocumented pt_discharge column
- Form cleanup: duplicate email questions - delete one so members cannot skip both

### iPad test checklist (v4.43)
- Submit a Forms test response for an existing client, let the pipeline run: all
  five sections render between Movement Screen and PT Discharge
- A yes on any screening question shows an amber Yes pill and the header chip
  shows the right flag count
- No answers render as No (this was the v4.40 string bug - verify explicitly)
- Unanswered questions produce no row; a client with no packet shows no section
- Completed date and MICROSOFT FORMS source pill render in the header

---

## v4.42 - July 9, 2026

Second half of the realtime load fix. Verification against the live
`supabase_realtime` publication (July 9) found only 5 tables actually publish
events; 8 of the app's 12 table-changes channels were subscribed to tables that
never emit - pure subscribe, sweep, and reconnect overhead on every iPad.

### Trigger
Follow-on from the v4.41 usage investigation: channel inventory against the live
publication showed 8 of 12 subscriptions were dead weight.

### Goal
Cut realtime message volume to what the publication can actually deliver, without
losing the wake catch-up refresh for the other entities.

### File version
v4.42 - 30,449 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **PUBLISHED_TABLES gate** - live channels open only for the 4 published entity
  tables (clients, classes, leads, trainer_time_off; notifications rides its own
  channel). The publication was verified 2026-07-09.
- **Wake refresh retained** - the 8 unpublished entities stay in the subscription
  list for wake-sweep catch-up, so they still converge on reload - they just no
  longer hold dead sockets.

### Test results
- Pre-push gates (`node --check` + tag check) - PASS
- Publication contents verified against the live database July 9 - note this
  supersedes the CLAUDE.md claim of 2 published tables from June 17

---

## v4.41 - July 9, 2026

Kills a self-sustaining realtime loop that had idle clients hammering Supabase at
roughly 180 classes UPDATE events per second with zero user input - about 5x the
Free-tier realtime message and egress caps, compounding daily.

### Trigger
Supabase usage running far over Free-tier caps with idle iPads - traced to the
realtime reload path.

### Goal
Stop the echo loop so idle devices generate near-zero load and the Free tier
holds until APC forces the infrastructure conversation.

### File version
v4.41 - 30,430 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Dirty-ref hydration on reload** - Root cause: realtime `reload()` called
  setState without hydrating the per-entity dirty-check ref (loadAll does). Every
  reload looked dirty, re-saved, the write echoed back as a postgres_changes
  event, and that retriggered reload. Worst on classes, whose JSONB round-trip is
  not stringify-stable. Reload now hydrates the ref, so echoes settle.
- **Wake sweep coalescing** - visibilitychange / online / pageshow reconnect
  sweeps coalesce instead of stacking, so an iPad waking from sleep fires one
  catch-up pass, not several.

### Test results
- Pre-push gates (`node --check` + tag check) - PASS
- Root cause reproduced from realtime event logs (~180 events/sec on classes with
  no user input) before the fix landed

---

## v4.40 - July 9, 2026

First cut of the Intake Paperwork render. Read-only ClientDetail section for the
CMRC Adult Fitness Pre-Assessment Packet stored as a single JSONB object on
`clients.intake_paperwork`. The original spec was not recoverable, so the field
shape was rebuilt from project memory and explicitly flagged as assumed - v4.43
corrected it the next day once the live form export existed. Shipping this cleared
the hold on the Section 5 decision-log pass (closed by ADR-0007 on Selisa's
verification).

### Trigger
The v4.39-era intake render spec was the standing blocker gating the Section 5
decision-log pass; spec text unrecoverable, rebuilt from project memory against
the pt_discharge and FMS patterns.

### Goal
Intake packets visible inside the app on the client record - no drive-diving
during a session - with a shape ready for the Forms ingestion pipeline.

### File version
v4.40 - 30,400 lines, 1.36 MB (RoundRock_Fitness_Tracker.html)

### Changes
- **Intake Paperwork section** - read-only render between Movement Screen and PT
  Discharge. Hidden entirely when absent for every tier (nothing to create
  in-app). Absent-guarded like pt_discharge, so it shipped safely before the DB
  column existed.
- **Definition-driven renderer** - INTAKE_SECTIONS constant is the single source
  of truth (CLEARING_TESTS pattern): renderer walks it, skips blanks and unknown
  keys, so the upstream shape can grow without breaking the render.
- **Helper lift** - boolPill and fieldRow lifted out of the PT Discharge IIFE to
  module scope as uiBoolPill / uiFieldRow for reuse.
- **Ingestion gap logged** - Microsoft Forms to Supabase ingestion added to
  BACKLOG.md as a separate build; intake_paperwork jsonb column SQL handed to
  Reagan (passthrough column, no translator entry needed).

### Test results
- `node --check` on the embedded JS - PASS
- Single commit +129/-14, tagged v4.40
- Render verified safe to deploy ahead of the ALTER TABLE: reads are null-guarded
  and no code path writes the key

### Deferred
- Field keys pending the live form export - resolved next day by v4.43
- iPad verification folds into the v4.43 checklist - v4.43 superseded this shape
  before it carried data, so test once against v4.43
