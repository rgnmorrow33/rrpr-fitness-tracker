# Round Rock Parks and Recreation - Fitness Tracker Update Log

**Live version: v4.52** (translator casing, audit_log and deleted_at round-trip snake, July 29, 2026)

Newest version at the top; append new sections above the older ones.

> Canonical running log, version-controlled in `docs/`. It previously lived only
> as a Word doc outside git and drifted (a stale v4.29 copy caused confusion on
> July 10). Keep it here going forward. `npm run log:scaffold` produces the raw
> material (SHAs, diff stats, file lists) for new entries.

---

## Current standing - July 29, 2026

- **Live version: v4.52**, tagged. Tracker file: 31,518 lines / 1.4 MB.
  `node --check` on the embedded JS: PASS. Netlify prod
  (pardfitnesstracker2) deploys on push to main.
- **v4.52 fixed a translator casing mismatch that had been silently destroying
  audit history and resurrecting soft-deleted records.** Four entities were
  renaming `audit_log`, `deleted_at`, and `deleted_by` to camelCase on load
  while every read site checked the snake name. Visible GX classes go 132 -> 72
  as 60 already-deleted duplicates stop rendering. Audit history before
  July 29 is gone and not recoverable.
- **The two-week gap between v4.48 and v4.49 was quiet on the app and busy on
  the data.** Live client count went 15 -> 35 over that stretch, almost all of
  it via the 8am weekday `purchase_import.py` run. That growth is what turned
  client lifecycle from a nice-to-have into the July 29 batch.
- **v4.49 shipped the lifecycle layer** (`packageValidDays`, `lastActivityDate`,
  `clientLifecycleStatus` + four threshold constants) and wired it to two
  surfaces: Active/Lapsed/Dormant/All pills on the AdminAllClients roster, and
  LAPSED/DORMANT pills on TopBar search rows.
- **v4.50 removed the last place that resolved package expiry its own way.**
  `sweepExpiringPackages` now goes through `packageValidDays` like everything
  else. Behavior-neutral against live data, deliberately fixed while it is.
- **v4.51 demoted `createdAt` to a fallback in `lastActivityDate`.** It had
  been a max participant, which meant every importer-created client looked
  freshly active. One live client reclassified: Melissa Harvey, lapsed ->
  dormant. Live buckets now 26 active / 0 expiring / 8 lapsed / 1 dormant.
- Live data as of July 29: 35 clients (non-deleted), 11 leads, 132 classes,
  21 trainers, 198 notifications. Realtime publication re-verified by direct
  query and unchanged: `classes, clients, leads, notifications,
  trainer_time_off`.
- anon still holds exactly ONE privilege in the entire `public` schema:
  `trainer_directory:SELECT`. No migrations have run since v4.46, so the 0008
  end state is intact.
- **Docs staleness sweep, July 29 (separate commit, no version).** Six files
  carried claims that were false as of v4.46 or v4.33 and had survived every
  version since. Corrected against the live database: CLAUDE.md Security
  posture (said RLS DISABLED on 17 tables and PINs plaintext; actual is RLS
  enabled on all 19, 55 policies, bcrypt PINs verified server-side),
  ARCHITECTURE.md sections 2, 4, 6 and 9, SCHEMA.md narrative prose,
  BACKLOG.md, DECISIONS.md (reading note plus two superseded markers),
  DEVICE_CHECKS.md, and the RLS runbook (banner marking it EXECUTED rather
  than pending). ARCHITECTURE.md also had the Netlify site labels **inverted** -
  it named `pardfitnesstracker` as production when that is the dead v2.x
  build. CLAUDE.md gained a "Before you write or execute a spec" preflight.

### Still open

- **The dedup-cleanup effect is armed for the first time as of v4.52.** It had
  been failing silently since it shipped, because the grouping pass skips rows
  where `c.deleted_at` is set and the translator was renaming that field away.
  Going forward it soft-deletes duplicate classes on app mount with no human in
  the loop. Harmless while the class table is clean; worth a decision before it
  is not.
- **The comment above `translate.timeOff` misdescribes the code as of v4.52.**
  It still reads "Other entities map auditLog<->audit_log in their translators
  - that is a pre-existing latent shape mismatch with appendAuditEntry; not
  fixed here." They no longer do. Docs commit, not a code commit.
- **Adjacent findings from the v4.52 audit, all unfixed.** `activeQueue` is
  computed and never consumed, and guards a `deleted_at` column that `leads`
  does not have (confirmed via `information_schema`). The `w.deletedAt` guard
  in `ConsultQueueView.unconvertedWROs` is permanently false since no WRO
  soft-delete path exists. `listTimeOffAllTrainers` has zero call sites.
  `translate.closures` registers an identity pair `['facility', 'facility']`.
  `softDeleteTrainerRecord` sets `deleted_at` without setting
  `is_active = false`, while `trainersStorage.load` filters only on
  `is_active`. `translate.contacts` has no `createdAt` pair but
  `makeFieldTranslator` drops `createdAt` unconditionally. DECISIONS.md claims
  `schedule_versions` uses `appendAuditEntry` when it has no call site and its
  `toSupabase` has no `audit_log` key at all.
- **The recency helper migration is specced but NOT built.** Repointing
  `clientPackageFlags` and `isClientCold` onto `lastActivityDate` is the
  obvious next move - both still carry their own recency logic, and
  `isClientCold` in particular reads `lastSeenDate`, which counts `scheduled`
  sessions. Re-measured against the shipped v4.51 helper: **1 cold flip, 1
  stale flip**, both Melissa Ladd, both the helper getting it right (her
  newest session row is an unsigned `scheduled` booking from June 16 while she
  bought a package on July 20). Down from 4 cold / 1 stale measured against the
  buggy v4.49 helper - three of those four were bug artifacts, not migration
  effects. Waiting on a spec.
- **Two clients sit 3 days from the dormant threshold.** Michael Hilliard and
  Jayasaree Kumar both resolve to 2026-04-03, which is daysSince 117 against a
  >120 cutoff. They tip on August 1 with no code change at all.
- **All five device checks in `docs/DEVICE_CHECKS.md` are still OPEN**, including
  P1 (does live sync between two iPads still work after the v4.46 RLS flip). That
  has now been open for 15 days. Code review cannot close any of them.
- **Rotate the anon key** pasted into chat on July 10. Hygiene, not urgency, now
  that RLS is on.
- **Row ownership is still app-side**, not enforced by RLS. Any signed-in trainer
  can update any client's row. Structural (sessions/packages/attendance live in
  JSONB on the parent row, ADR-0004). Acceptable for an internal team tool;
  revisit before APC.
- `intake-import/README.md` still documents the retired no-write posture.
  SCHEMA.md autogen regions miss `pt_discharge` and `intake_paperwork`.
  Test-FMS cleanup SQL is committed but never run.
- `scripts/staging/rls_staging_test.py` asserts `PASS anon can select clients`,
  correct for the retired 0003 model and a critical failure under the shipped
  model. `rls_identity_test.py` supersedes it. Retire the old one.
- **`.gitignore` still does not cover the untracked files that trip
  `release:tag`.** `--allow-dirty` remains the workaround. Open since v4.45.

---

## v4.52 - July 29, 2026

Three fields stop getting renamed on the way in from Supabase. Audit history
renders again, soft deletes survive a reload, and the 60 duplicate classes the
dedup cleanup has been trying to remove since it shipped finally disappear.

### Trigger

Read-only diagnostic audit requested against v4.49, run against v4.50. A static
trace had produced a hypothesis: `makeFieldTranslator` registers `audit_log <->
auditLog` and `deleted_at <-> deletedAt`, `fromSupabase` renames on every load,
and downstream guards that check the snake_case name go blind. Candidate, not
diagnosis. The audit was scoped to confirm or refute it, and to sweep every
registered pair rather than only the two suspected.

### Goal

A soft-deleted client, class, or time-off record should stay hidden after a
reload. An audit log should accumulate. Neither was true for `clients`,
`classes`, `leads`, or `trainer_time_off`.

### File version

v4.52 - 31,518 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

All three claims confirmed, two of them with the mechanism wrong.

**Soft deletes were never lost.** `softDeleteClient` does `Object.assign({},
before, { deleted_at: ..., deleted_by: ... })` on a record that already carries
`deletedAt` from `fromSupabase`. Both keys resolve to `deleted_at` in
`toSupabase`, and because `Object.keys` walks creation order and the snake key
was added last, snake won. The Postgres row was correctly stamped every time.
What broke was the read: after the next load the record carries `deletedAt`
only, and all ~20 guards test `deleted_at`. The record was permanently deleted
in the database and permanently visible in the app.

**Audit logs were replaced, not truncated.** `appendAuditEntry` starts from
`(record.audit_log || [])`, which post-load is `[]`, so every write persisted a
one-element array over the full history. The 100-entry head-trim never fired.
`clients`, `classes`, and `leads` are all in the realtime publication, so each
write echoed back, triggered the 100ms debounced reload, and reset the record
before the next append. Steady state was one entry, forever.

Confirmed against live data, not just source:

- Audit depth by table. `clients` deepest 2 (26 of 36 rows at exactly 1),
  `classes` deepest 2 (60 of 132 at 1), `leads` deepest 1. Controls that keep
  snake in memory: `trainers` deepest 3 with 8 of 21 above one entry,
  `trainer_time_off` deepest 3 with 11 of 12 above one entry.
- Zero reads of `.auditLog` anywhere in the file. `fromSupabase` was writing a
  key nothing consumed.
- 60 of 132 classes carried `deleted_at` and were rendering as active.
- The clincher: all 60 shared one timestamp to the millisecond,
  `2026-07-29 15:43:00.322+00`, five minutes old when queried. That can only
  come from a single `new Date().toISOString()` in one `setClasses` updater.
  The dedup-cleanup effect skips rows where `c.deleted_at` is set, which
  post-reload is never, so it re-detected the same 60 duplicates and rewrote
  them on every app mount. It had been failing silently since it shipped.

`closures` came back at zero audit entries across all 12 rows and was initially
read as a failing control. It is not a control at all: all 12 are
`SEED_CLOSURES_2026`, seeded straight into state via `useState`, and
`addClosure` / `removeClosure` have never run in production.

### Changes

- **`translate.clients`** - removed `['auditLog', 'audit_log']`,
  `['deletedAt', 'deleted_at']`, `['deletedBy', 'deleted_by']`.
- **`translate.classes`** - removed the same three.
- **`translate.leads`** - removed `['auditLog', 'audit_log']`. Leads has no
  `deleted_at` column (confirmed via `information_schema`), so there was
  nothing else to strip.
- **`translate.timeOff`** - removed `['deletedAt', 'deleted_at']`,
  `['deletedBy', 'deleted_by']`. Its `audit_log` was already correctly out of
  the map.
- **`BulkImportClientsModal.buildClientPayload`** - `auditLog: []` becomes
  `audit_log: []`. Without this the stripped pair turns it into a bogus
  `auditLog` column and every bulk import dies on PGRST204.

Diff: **+1/-10**. The four entities now match `trainers` and `closures`, which
have kept these fields snake-case in memory all along.

Side effect worth knowing: `AUDIT_NOISE_KEYS` lists `audit_log` but not
`auditLog`, so the noise filter in `diffRecords` was not covering the key these
records actually carried. It covers it now, for free.

### Test results

- `node --check` on the embedded JS extracted from the patched file - PASS.
- **Post-fix orphan sweep** across the whole file: zero remaining code
  references to `auditLog`. The 15 remaining `deletedAt` / `deletedBy` hits are
  all `translate.scheduleVersions`, which is a separate custom translator that
  is camel-case by design and correct, plus the one dead `w.deletedAt` guard on
  WROs.
- **Round trip executed against the real patched translator**, extracted from
  the edited file and run on a representative row: `audit_log` appends 3 -> 4
  instead of collapsing to 1, exactly one `audit_log` and one `deleted_at` key
  reach the wire instead of two each, and a soft-deleted record still reads
  `deleted_at` after a simulated reload.
- **Pre-ship gate against live data.** Rebuilt the dedup key
  (`name|dayOfWeek|startTime|location|instructor`) in SQL and grouped all 132
  classes. All 52 duplicate groups returned `surviving = 1`. Eight classes had
  three copies, forty-four had two, 8x2 + 44x1 = 60. The complement query
  (groups where every copy is deleted) returned zero rows, so no class
  disappears entirely.
- **Not verified: on-device behavior.** No iPad check has been run against
  v4.52. The checklist below is untouched.

### Deferred

- **The comment above `translate.timeOff` is now wrong.** It reads "Other
  entities map auditLog<->audit_log in their translators - that is a
  pre-existing latent shape mismatch with appendAuditEntry; not fixed here."
  As of this version they do not. Left in place per the defer-cleanups rule;
  it belongs in a docs commit, not this one.
- **The destroyed audit history is not recoverable.** This protects everything
  from July 29 forward and nothing before it.
- **The dedup-cleanup effect is now armed for the first time.** It has been
  firing blanks; going forward it soft-deletes duplicate classes on app mount
  with no human in the loop. That behavior was never separately decided and
  should be.
- Adjacent findings from the audit, none fixed. Full list in Still open above.

### iPad test checklist for v4.52

- Open a client with recent activity and tap Audit History. Should list
  multiple entries. **If it still says "No audit entries yet" after you make a
  change and reopen it, the fix did not take - roll back.**
- GX schedule should show 72 classes, not 132, and no visible duplicate rows.
- Admin > All Classes > Show deleted should now report 60.
- Soft-delete a throwaway test class, wait for the sync dot to settle, reload.
  **If it reappears in the active list, the fix did not take.**
- Time-off manager: the one previously-deleted row should be gone from the
  active list.
- Run the regression probe SQL, have someone open the tracker, run it again.
  The `deleted_at` timestamp on those 60 rows should be identical both times.
  **If it advances, the dedup loop is still running.**

### The lesson

Two, and they are both about evidence rather than code.

A static trace gets the existence of a bug right and the mechanism wrong in
whichever direction sounds most alarming. This one called the soft-delete
failure a lost write when the write was fine and the read was blind, and called
the audit-log failure a truncation when it was a full replacement. Neither
correction changes whether you fix it. Both change what you tell people and
what you check afterward.

And when you pick a control group, verify the control has ever been exercised.
`closures` looked like a clean comparison and was twelve seed rows that no
human has ever touched.

---

## v4.51 - July 29, 2026

`createdAt` stops voting on how recently a client was active.

### Trigger

Shipped in v4.49 and caught while building v4.50. `lastActivityDate` took the
max of three dates, and one of them was a row-insert timestamp.

### Goal

Recency should mean the client did something. Not that a batch job touched
their row.

### File version

v4.51 - 31,527 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

`lastActivityDate` resolved as `max(qualifying session date, package
purchaseDate, client.createdAt)`. For clients created by hand the third term is
harmless - they were created the day they showed up. For importer-created
clients it is not: `purchase_import.py` stamps `created_at` at row-insert time,
which lags the real purchase by up to **66 days** observed live.

So a client who bought a package on March 8, never booked a session, and got
swept into the app by the importer on May 13 resolved to May 13. Seventy-seven
days stale instead of a hundred and forty-three. `clientLifecycleStatus`
consumes this, and it is live on the AdminAllClients roster pills and the TopBar
search rows, so the front desk was being told someone was merely lapsed when
they had been gone nearly five months.

### Changes

- **`createdAt` is now a last-resort fallback, not a max participant.** Session
  and package dates still max against each other exactly as before. If either
  resolves, that wins. Only when there is no qualifying session AND no
  non-deleted package does the helper fall through to `createdAt`.
- **The comment above the helper names the import-lag reason explicitly**, in
  the terms that make re-adding the max look like the mistake it is. Without
  that, the next reader restores it in good faith.
- Null defense unchanged: all three resolving null still returns null, and
  `clientLifecycleStatus` still buckets that as `active`. A record is never
  hidden for missing data.
- Untouched by design: `clientPackageFlags`, `isClientCold`,
  `daysSinceLastSeen`, `lastSeenDate`, every threshold constant, and the
  qualifying session-status list.

Diff: **+15/-10** against a ~+8/-6 target. Code-only is +2/-5, net negative;
the overage is the mandated comment (+12/-4) plus the footer bump.

### Test results

- `node --check` on the embedded JS - PASS.
- **Nine assertions against the real shipped helper source** extracted from the
  edited file, on synthetic objects, no database writes and no test rows in
  production. All pass: session-recent-beats-package-old, the reverse, the bug
  case (no sessions, package 60 days old, `createdAt` 5 days ago - package
  wins), no-sessions-no-packages falls to `createdAt`, `scheduled` sessions
  still do not qualify, `late_cancel` / `no_show` / `excused` all do, deleted
  packages ignored, all-null returns null, and the all-null client still
  buckets `active`.
- **Live effect, measured not predicted: exactly one client moves.** Melissa
  Harvey, lapsed -> dormant, resolved date 2026-05-13 -> 2026-03-08. Twenty-three
  of 35 clients get a different resolved date; only she crosses a threshold.
  Live buckets after: 26 active, 0 expiring, 8 lapsed, 1 dormant.

### The gate, and why it was waived

The spec gated Phase 2 on zero clients changing bucket. It returned one, so the
fix was held and reported rather than shipped. Reagan waived it.

That was the right call and the gate was the thing that was wrong. "Prove
nothing moves" is a reasonable guard against an accidental reclassification, but
this fix exists *because* something should move. Melissa Harvey bought one
package on March 8, logged zero sessions, and has not been seen since. Dormant
is what she is. A gate that blocks a correct reclassification is measuring the
wrong thing - the useful question was never "does anything change," it was "is
every change correct," and at n=1 that was answerable by reading the row.

### Deferred

- **Michael Hilliard and Jayasaree Kumar tip on August 1.** Both resolve to
  2026-04-03, daysSince 117 against a >120 dormant cutoff. No code change
  required; they cross on their own in three days. Flagged so it does not read
  as a regression when it happens.
- The recency helper migration (`clientPackageFlags` / `isClientCold` onto
  `lastActivityDate`) is still unbuilt. Flip counts are in Still open.

---

## v4.50 - July 29, 2026

One resolution path for package expiry instead of two. Behavior-neutral today,
which is the entire reason to do it today.

### Trigger

v4.49 added `packageValidDays` with the correct precedence and pointed the new
lifecycle surfaces at it, but deliberately left `sweepExpiringPackages` on its
own inline resolution ("Diverges from sweepExpiringPackages on purpose - see
spec"). That deferral was correct for v4.49's blast radius and wrong to leave
standing.

### Goal

Kill the divergence while the data that would expose it does not exist yet. A
behavior-neutral swap is a code review. The same swap in three months is a
migration with live consequences.

### File version

v4.50 - 31,522 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

`sweepExpiringPackages` resolved a package's validity window as:

    validDaysOverride ?? template.validDays

It never read `pkg.validDays`. But `purchase_import.py` stamps `pkg.validDays`
with the real RecTrac span at import, and `packageValidDays(pkg)` - already live
behind the v4.49 lifecycle pills and the TopBar search rows - resolves
override -> `pkg.validDays` -> catalog default. So the same package could be
"expiring" to the roster pill and not expiring to the notification sweep.

Why it has not bitten yet: every stamped `validDays` currently in production
equals its catalog default (365 across the board), so the two paths agree on all
35 active packages. The types where the divergence is structural rather than
accidental are **Baca-Pairs-4 (30 day catalog default)** and **Baca-Pairs-8
(60 day)** - a stamped 90-day span on either one would have resolved to 30 or 60
in the sweep and 90 everywhere else. Both have **zero live rows** right now.

That emptiness is the argument for fixing it now, not the argument for waiting.

### Changes

- **`sweepExpiringPackages` calls `packageValidDays(pkg)`.** The inline
  `validDaysOverride ?? template.validDays` ternary is gone.
- **The sweep's local `resolveTemplate` copy is deleted.** It existed only to
  feed that ternary. The package label - the one other thing it fed - now
  resolves through the module-scope `resolvePackageTemplate`, which is the same
  lookup with one extra guard.
- Three comment blocks corrected in the same pass, because all three asserted
  the divergence was intentional and would have invited someone to re-add it:
  the sweep's header block, `resolvePackageTemplate`'s "kept as a separate copy
  on purpose," and `packageValidDays`'s "diverges from sweepExpiringPackages
  on purpose."
- Untouched by design: the band logic (0/7/14), the dedupe key
  (`pkg.id + ':' + band`), `sessions_low` (count-driven, not expiry-driven),
  and `clientLifecycleStatus`.

Diff: **+9/-29** against a ~+6/-25 target. The overage is entirely the three
comment corrections (+5/-5) plus the footer bump (+1/-1); the code-only diff is
+3/-23.

### Test results

- `node --check` on the embedded JS - PASS (via
  `scripts/hooks/pre-push-syntax-check.js --git`).
- **Precedence verified on 13 synthetic package objects in node**, running the
  real `packageValidDays` / `resolvePackageTemplate` source extracted from the
  shipped file. All three branches proven: override wins over everything;
  stamped `validDays` beats the catalog default; bare package falls to the
  catalog default via either `template_id` or `type`. Includes the
  Baca-Pairs-4 case (catalog 30) carrying `validDays: 90`, which has no live
  coverage - old path resolved 30, new path resolves 90. Also covers
  `validDaysOverride: 0` (respected, not treated as absent) and the consult /
  legacy-seed rows that resolve null and get skipped. No database writes, no
  test rows in production.
- **Divergence re-run against live data after the swap: 0 packages.** 35 active
  packages across 35 non-deleted clients, 20 carrying a stamped `validDays`, 0
  with an override, 0 where old and new resolution disagree. The swap changed
  nothing for live data, which is what it was supposed to prove.
- The v4.49 Fix A follow-up (comment-only disambiguation of
  `addDays` / `addDaysYMD` / `daysBetween`, commit `3d31c33`) rides in this
  version. It had been pushed to a stranded branch instead of main and was
  merged clean, +6/-0, one file, no behavior change.

### Deferred

All of these are filed in `docs/BACKLOG.md` in this same commit, not just noted
here. `sessionConsumption` went into a new **Open correctness questions**
section rather than the cleanup pile, because it changes numbers on live
records and "address when convenient" is the wrong instruction for it.

- **The disambiguation comments merged in `3d31c33` reference call sites by
  line number** (4770, 5576, 5585). CLAUDE.md's no-line-numbers rule is scoped
  to `/docs`, so this is not a violation, but the same reasoning applies harder
  inside a 31k-line file that drifts every version - this v4.50 diff already
  moved two of the three. Worth converting to name-only references.
- **`sessionConsumption` counts `scheduled` sessions as consumed.** Only
  `excused` returns 0, so a booked-but-unsigned session deducts from
  `sessionsRemaining` exactly like an attended one. Spotted while measuring
  lifecycle buckets; not touched. Needs its own version and its own decision,
  since it changes remaining-session math on live records.
- **Sessions still have no per-package linkage on the client-wide remaining
  count**, already flagged in the sweep's own comments. Unchanged.

---

## v4.49 - July 29, 2026

Client lifecycle status. Four fixes, one commit, the first three of them
groundwork for the fourth.

### Trigger

The roster had grown past the point where "who has drifted away from us" was
answerable by looking at it. 35 clients, a two-week import ramp, and no way to
separate someone who trained last week from someone who bought a package in
March and never came back.

### Goal

A pure, unwired lifecycle classifier with real thresholds, plus the two smallest
surfaces that make it useful: a roster filter and a duplicate-record guard at
the front desk.

### File version

v4.49 - 31,536 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`).
Commit `78f6f71`, +175/-19.

### Changes

**Fix A - date-helper consolidation.** `sweepExpiringPackages` carried a local
`addDays` and a local `daysBetween`. The sweep-local `addDays` was deleted
outright and the sweep repointed at the pre-existing module-scope `addDaysYMD`;
`daysBetween` had no existing equivalent and hoisted to module scope unchanged.

**Fix B - the lifecycle helpers.** Three module-scope functions plus four
threshold constants, all pure, no writes, no persistence, no schema:

- `packageValidDays(pkg)` - override -> stamped `pkg.validDays` -> catalog
  default.
- `lastActivityDate(client)` - latest of qualifying session date, package
  purchase date, or client creation. `scheduled` sessions do not count; an
  unsigned future or stale booking should not prop up recency.
- `clientLifecycleStatus(client, today)` - `active` | `expiring` | `lapsed` |
  `dormant`. Recency gates first, package state only refines the recent bucket
  into active vs expiring. Null-defends toward `active`: a client with no
  resolvable activity date reads as active, never as a reason to hide a record.
- `LIFECYCLE_LAPSED_DAYS` 45, `LIFECYCLE_DORMANT_DAYS` 120,
  `LIFECYCLE_EXPIRING_DAYS` 30, `LIFECYCLE_EXPIRING_SESSIONS` 2.

**Fix C - roster filter pills.** Active / Lapsed / Dormant / All on
AdminAllClients, orthogonal to the existing package-alert chips. Counts computed
once against the full client set (not the current filter) and memoized against
`ctx.clients`, because this is a full `clientLifecycleStatus` pass over every
client and it must not redo that work on every keystroke.

**Fix D - search-row status pills.** LAPSED / DORMANT pills on TopBar global
search results. This is the one with an actual operational job: it stops the
front desk from creating a duplicate record for a returning member. Search
matching itself stays unfiltered across all statuses - the pill informs, it does
not hide.

### Test results

- `node --check` on the embedded JS - PASS.
- Came in at **+175/-19 against a ~+155/-15 target**. The overage was
  `resolvePackageTemplate`, flagged before commit and approved rather than
  absorbed silently.

### Deferred

- `clientPackageFlags` and `isClientCold` still carry their own recency logic
  and were **not** migrated onto `lastActivityDate`. Named as a future migration
  target in the code comments. Still open as of v4.50.
- `packageValidDays` was left deliberately diverging from
  `sweepExpiringPackages`. Closed in v4.50.

### The lesson

The Fix A precondition asked the wrong question. It asked a **closure** question
- can this local function safely be hoisted out of its enclosing scope - when
the real risk was a **namespace** question: is that name already taken at module
scope, and by what?

It was. A module-scope `addDays(d, n)` already existed, and it takes and returns
`Date` objects, not YMD strings. The sweep's local `addDays` was the YMD-string
variant. A naive same-name hoist would have compiled fine, passed `node --check`
fine, and silently shadowed the Date-based helper across **30-plus call sites**
- payroll, week navigation, and the schedule builders - every one of which would
have started passing a `Date` into a function expecting `'YYYY-MM-DD'`. Nothing
would have thrown. Dates would just have been wrong, on a payroll surface.

What caught it was reading module scope for the name before moving anything, not
the syntax check and not the diff review. Both of those would have passed.

The follow-up was to cross-reference all three date helpers in comments so the
next reader reaches for the right one. That pass got pushed to a stranded branch
and sat unmerged for the rest of the day, which is its own small lesson about
where work lands: it shipped with v4.50, not v4.49.

**Before hoisting anything, grep the destination scope for the name. Not for the
behavior - for the name.**

---

## v4.48 - July 14, 2026

Makes the smoke suite's realtime guard real, and corrects a CLAUDE.md claim that
was wrong in the dangerous direction. Both found while closing out v4.47.

### Trigger

Auditing the v4.47 fix surfaced that the guard which caught it was itself broken,
and that the file Claude reads at the start of every session says the opposite of
what the database actually does.

### Goal

A realtime channel that drops and never comes back fails the suite. And nobody
designs the next feature off a false statement about which tables sync live.

### File version

v4.48 - 31,380 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

**1. The recovery gate was decorative.** `consoleGuard` computed:

    const realtimeRecovered = messages.some(
      (m) => m.text.startsWith('[realtime] reconnected') ||
             m.text.startsWith('[realtime] subscribed'),
    );

`subscribeWithReconnect` logs `[realtime] subscribed <key>` unconditionally at
channel open, BEFORE `.subscribe()` is called. So `realtimeRecovered` was ALWAYS
true, so `isRealtimeTransient(...) && realtimeRecovered` dropped every
`status=CLOSED` and `scheduling reconnect` warning, unconditionally. The comment
above it claimed *"a genuine UNrecovered drop still fails the suite."* It could
not. That is precisely the "subs actually drop in production" P1 the guard exists
to catch.

Deleting the `subscribed` clause alone would NOT have fixed it - it would have
made the suite flaky. `[realtime] reconnected` only prints when
`backoffMs !== BACKOFF_INITIAL_MS`, and `sweepReconnectChannels` RESETS
`backoffMs` to INITIAL before reconnecting. Whether it prints at all depends on a
race between the torn-down channel's CLOSED and the new channel's SUBSCRIBED. The
app had no deterministic "this channel is live" signal to gate on. So the app had
to change first.

**2. CLAUDE.md was wrong about the publication.** It said the
`supabase_realtime` publication held 2 tables (`notifications`,
`trainer_time_off`, "verified June 17") and that "every other entity converges
only on reload, not live push." Queried against the live database:

    classes, clients, leads, notifications, trainer_time_off

Five tables. `clients`, `classes` and `leads` DO push live. v4.42 already noted
the contradiction and nobody went back and fixed the file. It also still described
the single `app-changes` channel that v4.33 replaced with per-table channels.

### Changes

**App**

- **`_handleChannelStatus` emits `[realtime] live <key>` on every SUBSCRIBED**,
  unconditionally. Deterministic per-channel liveness signal, no race.

**Tests**

- **`consoleGuard` gates recovery PER CHANNEL.** New `transientChannelKey()`
  extracts the channel key from a CLOSED / scheduling-reconnect warning; the
  transient is dropped only if that key later appears in a `[realtime] live`
  message. A channel that drops and never returns keeps its warning and fails.
- `status=CHANNEL_ERROR` and `status=TIMED_OUT` remain non-transient. They are
  never dropped, recovered or not.

**Docs**

- **CLAUDE.md realtime section rewritten** against the live publication, with the
  verification query inline so the next person can re-check in one paste.

### Test results

- `node --check` on the working-tree embedded JS - PASS
- Publication verified by direct query against the live database
  (`pg_publication_tables`), not from memory or from CLAUDE.md.
- Corrupt-artifact question from v4.47 CLOSED: the `upload-artifact` step has no
  `continue-on-error`, so a failed upload fails the job. Run #46 concluded
  `success`, therefore the artifact uploaded cleanly. The zip errors in the failing
  run attached to test 8 RETRY 1 - a truncated trace from a retrying test, not an
  independent bug. Green suite, no retries, no recurrence.
- Tagged v4.48 before push per tag-on-release.

### Deferred

- **The one that matters: are pre-auth channels re-authorized on sign-in?** See
  Still open. If they are not, live sync for clients / classes / leads has been
  silently dead since v4.46 and only the two-iPad check will reveal it.

### iPad test checklist for v4.48 specifically

- Load the site and sign in. Console shows `[realtime] live table-changes-<table>`
  for clients, classes, leads and trainer_time_off. Four of them.
- **Drop a class for sub coverage on one iPad. It should appear on a second iPad
  WITHOUT reloading.** If it only shows up after a reload, live sync is broken and
  the pre-auth channel question above is answered: badly.

### The lesson

The guard that caught v4.47 was itself broken, and it had been broken the whole
time it was passing. It reported a real bug accurately while being incapable of
reporting the specific bug it was written for.

Two safety nets have now been found decorative in one day: this one, and CLAUDE.md
itself, which confidently stated the opposite of what the database does. Both read
as verified. Neither was. v4.42 even noticed the CLAUDE.md contradiction, wrote it
down in a version entry, and moved on without fixing the file.

Noticing is not fixing. Write it down AND go change the thing.

---

## v4.47 - July 14, 2026

The first piece of v4.46 fallout. The security pass locked the database down
correctly; it did not teach the whole app that it was locked down. The realtime
reload path kept reading tables that anon can no longer touch, from the one
screen where nobody is signed in - the login screen, which is where every iPad
sits most of the day.

### Trigger

The post-deploy smoke suite went red on all 9 admin views within hours of the
v4.46 flip. The failure list read like nine separate regressions. It was one bug,
and the suite was reporting it correctly.

### Goal

A signed-out iPad sitting on the login screen issues zero requests the database
is guaranteed to refuse.

### File version

v4.47 - 31,371 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

Nine failing tests, zero failing assertions. Every view rendered. Every failure
came from the `consoleGuard` auto-fixture, which fails any test that prints
console output outside the allowlist. The console was printing this, eleven times
over, on every test:

    Subscription reload failed for clients: {code: 42501,
      hint: ...GRANT SELECT ON public.clients TO anon,
      message: permission denied for table clients}

The role in those errors is **anon**, not `authenticated`. Post-login the custom
`global.fetch` attaches the JWT, so these were firing while signed OUT.

The realtime subscription effect ends with `}, []);`. Empty deps: it mounts once,
while signed out, and never re-runs on the auth flip. Inside it, `wakeCatchUp()`
fires all 12 entity reloaders with no gate, and it is wired to three listeners -
`online`, `visibilitychange`, and `pageshow`.

**`pageshow` fires on every normal navigation, not just BFCache restore.** So this
was never a wake-only edge case. Every single page load of the login screen fired
12 reads as anon. Eleven came back 42501; the twelfth (`trainers`) survives
because anon can read it through the `trainer_directory` view. The report showed
exactly 11 denied tables. That is the whole mystery.

`loadAll()` already gates on `isStaff()` - v4.46 added that gate for precisely
this reason. The `reload()` path did not get one. Same blind spot as v4.41, where
`reload()` was also the function that missed what `loadAll()` already did.

### Changes

**App**

- **`reload()` now gates on `isStaff()`** (one line, inside the debounced body).
  Gating there rather than in `wakeCatchUp()` covers BOTH call paths, since the
  postgres_changes event handler funnels through `reload()` too. No data is missed
  on sign-in: `loadAll` re-runs on `[authVersion]` and pulls every entity fresh.

**Tests**

- **New smoke test `0. signed-out login screen fires no RLS-denied reads`.** Loads
  the login screen signed out, dispatches all three wake events by hand (rather
  than hoping the browser emits one), and asserts zero `permission denied` /
  `Subscription reload failed` console output. The `consoleGuard` fixture would
  also catch a regression here, but as an anonymous wall of noise. This test names
  the bug.

### Test results

- `node --check` on the embedded JS - PASS
- Working-tree JS extracted and checked directly, NOT via the pre-push gate. The
  gate checks HEAD (the content a push would ship), so running it against an
  uncommitted change validates the wrong file. See The lesson.
- Tagged v4.47 before push per tag-on-release.

### Deferred

- **The smoke suite's realtime recovery gate is decorative.** See Still open.
- **Corrupt report artifact.** Both zip errors in the failing run
  (`End of central directory record signature not found`) attach to test 8 retry 1
  specifically, as test errors with an `error-context` attachment - not to the
  `upload-artifact` step, whose config is correct. Reads as a truncated trace on
  one retry, not a systematic break. Re-check on the next run; if it recurs on
  test 8 and only test 8, dig then.
- **Anon realtime channels open pre-auth.** The four published-table channels are
  opened while signed out, as anon. Evidence says this is benign: `CHANNEL_ERROR`
  is not matched by `isRealtimeTransient`, so it would have surfaced as an
  offender, and ZERO `[realtime]` errors appear anywhere in the failing run. The
  channels join, deliver nothing under RLS, and `realtime.setAuth()` re-authorizes
  them on sign-in. What is NOT proven from the report: that events actually flow
  on a channel opened pre-auth. Verify with the two-iPad sub-coverage check in the
  v4.46 checklist.

### iPad test checklist for v4.47 specifically

- Load the site signed out and open devtools. The console should be quiet. Before
  this fix it filled with `permission denied for table` on every load.
- Reload the page three or four times signed out. Still quiet.
- Sign in. Data loads normally (this is `loadAll` on the auth flip, not `reload`).
- Drop a class for sub coverage on one iPad, claim it on a second. Live sync still
  works - the gate must not have broken the post-auth reload path.
- Background the app, wait, bring it back. The wake catch-up still converges.

### The lesson

The smoke suite did its job perfectly and still nearly got blamed. Nine red views
looked like nine regressions and read like a stale test suite that needed
updating to match the new auth model. The correct move was the opposite: not one
assertion had failed, the app was fine, and the suite was reporting a real bug in
the app with total accuracy.

The tempting fix was to add `42501` to the console allowlist and go green. That
would have deleted the only thing that caught this, and it is the same move v4.46
warned about: *"the linter would have gone green and the database would have
stayed wide open. That is the worst outcome available: believing you are done."*

When the tests go red right after a big change, the reflex is that the tests are
stale. Check which assertion failed before you believe it. Here, none had.

---

## v4.46 - July 14, 2026

The security pass. Takes the database from "anyone on the internet can read every
client record" to "you must be a signed-in team member, and the database enforces
it." Hashes every PIN, moves PIN verification server-side, gives the database a
real identity to key on, and enables RLS with policies that key on that identity
rather than on `true`.

### Trigger

A review of the Supabase security posture, prompted by a plain question: what
would change if RLS were turned on? The audit found the honest answer was "you
can't." There was no Supabase Auth in the codebase at all - no `supabase.auth.*`
call anywhere - so `auth.uid()` was always null and RLS had nothing to key on.
Sign-in was a client-side PIN comparison held in React state; the database never
learned who was asking. "Turn RLS on" was never actually an available move. The
real work was giving the database an identity first.

### Goal

Client names, emails, phones and PAR-Q health answers are not readable by the
public internet. The team signs in the way they always have (tap name, type a
4-digit PIN, on a shared iPad) and notices nothing different.

### File version

v4.46 - 31,358 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### Seven bugs, and how each was found

None of these were found by reading code. Every one surfaced by running the thing
against a real database. That is the whole lesson of this pass.

1. **The `allow all` policies. RLS would have been purely cosmetic.**
   Twelve tables already carried a policy named `allow all`
   (`FOR ALL TO anon USING (true) WITH CHECK (true)`), inert only because RLS was
   off. The staged `0003` never dropped them. Postgres OR's permissive policies
   together, so enabling RLS would have activated them and changed nothing: anon
   keeps full read/write, DELETE included. The Supabase linter would have gone
   green and the database would have stayed wide open. **That is the worst
   outcome available: believing you are done.**
   Reproduced on a throwaway table (with `allow all` alongside
   `anon_select ... USING (key <> 'admin_pin')`, anon still read the admin_pin
   row; dropping `allow all` and changing nothing else, anon read zero).
   Fixed with a STEP 0 drop block plus a `DO $$` assertion that aborts the
   migration if any `allow all` survives.

2. **The `crypt()` search_path bug. Total, unrecoverable sign-in lockout.**
   The four PIN functions in `0002` declared `SET search_path = public, pg_temp`,
   but `pgcrypto` lives in the `extensions` schema on Supabase, so `crypt()` is
   unresolvable at runtime. The migration *appears* to succeed: the backfill works
   (migrations run with a wide search_path), `UPDATE trainers SET pin = NULL`
   destroys every plaintext PIN, and it commits green. Then the first person taps
   their tile and gets `function crypt(text, text) does not exist`.
   `rls_emergency_rollback.sql` would not have saved us - it explicitly assumes
   "the PIN RPCs keep working," and they would not have; the failure is
   independent of RLS. The old HTML could not be redeployed either, because it
   compares plaintext PINs that step 2 just deleted. Net: every iPad locked out,
   no path back, recoverable only by hand-writing SQL under pressure.
   Fixed by adding `extensions` to the search_path, plus a SELF-TEST block that
   calls the RPCs for real before COMMIT.

3. **The token never reached PostgREST.** The first cut of the app wiring set
   `supabaseClient.rest.headers.Authorization`, assuming supabase-js reads that
   object at query time. It does not. Every request kept going out as anon and the
   app died on `permission denied for table trainers ... TO anon`.
   Fixed by injecting the token through a custom `global.fetch` passed to
   `createClient`: public API, runs on every PostgREST and RPC call, reads the
   token live, so an auth flip needs no client recreation and orphans no realtime
   channel.

4. **Spurious empty-array upserts. A data-loss bug, introduced by this pass.**
   The entity dirty-check refs initialise to `useRef(null)`, and `_saveIfDirty`
   treats `null` vs `[]` as dirty. The new pre-auth `loadAll` path hydrated only
   `trainerProfilesRef` and returned early, so the instant `loading` flipped false
   the app fired a SAVE for the other twelve entities - upserting **empty arrays
   over the server's data**. RLS is the only reason nothing happened; the console
   filled with `Save clients failed: permission denied`. On the open production
   database those writes would have LANDED.
   Fixed: the pre-auth path hydrates all thirteen refs, and doubles as the
   sign-out flush.
   **The lockdown caught a data-loss bug that the open database would have
   silently executed.**

5. **The kiosk regression. Caught at the go-live gate, minutes before the flip.**
   The login screen has two PUBLIC, no-PIN member tiles:

       "Weight Room Orientation Sign-Up"  -> upsertWRO()            -> writes `wros`
       "Book a Consultation"              -> auditedUpsertClient()  -> writes `clients`

   Both run with no token; both would have returned `permission denied`. A member
   fills in the entire orientation form, taps submit, and gets an error. The app
   even documents the intent (`Front Desk attribution when no session is active`).
   Granting anon the access back was not an option: the saves use
   `.upsert(..., {onConflict:'id'})`, which needs INSERT **and** UPDATE, and
   anon INSERT+UPDATE on `clients` is most of the door we just shut.
   Fixed in `0006` with a write-only kiosk identity (see Changes).

6. **PUBLIC execute on the PIN setters. Caught by the linter, after I asserted it
   was fixed.** Postgres grants EXECUTE to PUBLIC by default on function creation,
   and anon inherits through PUBLIC. `0005`'s `REVOKE ... FROM anon` therefore did
   nothing: anon could still reach `/rest/v1/rpc/set_trainer_pin` and
   `set_admin_pin`. Not exploitable (both check `app_is_admin() OR
   app_is_service_role()` and return `forbidden`), but that is one layer of
   defence where there should be two.
   Fixed in `0007` with `REVOKE ... FROM PUBLIC` plus a `has_function_privilege`
   assertion. **Verify, do not assume - including when the assertion comes from
   me.**

7. **`trainer_directory` was WRITABLE by anon. Live privilege escalation, found
   two hours after go-live, while double-checking work I had already called done.**
   Supabase ships DEFAULT PRIVILEGES granting ALL on newly-created objects in
   `public` to anon. `0005` ran `REVOKE ALL ON ALL TABLES ... FROM anon` at step 2
   and then `CREATE VIEW trainer_directory` at step 3. The view was born *after*
   the revoke, so it picked up the defaults: anon got INSERT, UPDATE, DELETE and
   TRUNCATE on it. A revoke cannot cover an object that does not exist yet.

   The view is SECURITY DEFINER (by design, so the login screen can read names
   pre-token) and auto-updatable, so writes through it execute as the view owner
   and **bypass RLS on `trainers` entirely.** Verified exploitable on production:

       anon UPDATEs trainers via the view ... 1 row
       anon INSERTs a trainer via the view .. 1 row
       anon DELETEs a trainer via the view .. blocked only by an incidental FK

   Anyone on the internet could insert, rename or modify team members. The delete
   failed only because that trainer happened to have notifications rows.

   Roster was writable for roughly two hours. Checked afterwards: 21 trainers,
   3 admins, zero rows created or updated in the window, no suspicious names.
   Nobody found it.

   Fixed in `0008`: `REVOKE ALL` then `GRANT SELECT` on the view, plus
   `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon` so
   the next object created cannot repeat it.

   **The policies were right. The GRANTS were wrong.** A policy audit says nothing
   about privileges. This was found only by enumerating
   `information_schema.role_table_grants` and asking why a number was 7 - after
   everything had been declared finished, verified, and shipped.

### Changes

**Database**

- **`0002_pin_hashing.sql`** - bcrypt-hashes every PIN into a `trainer_pins`
  table with no anon access, hashes the Front Desk PIN in place, moves
  verification into `verify_trainer_pin` / `verify_admin_pin` RPCs with a
  5-failures-in-15-minutes lockout, and drops the plaintext `trainers.pin` column.
  Carries the search_path fix and a self-test that aborts rather than committing a
  broken PIN path.
- **`0003_rls_policies.sql`** - **RETIRED, never run.** Every policy in it is
  `anon USING (true)`, which enables RLS but leaves `clients` world-readable. Kept
  in the repo for history only. Do not run it.
- **`0004_auth_identity.sql`** - gives the database an identity.
  `sign_in(trainer_id, pin)` delegates the PIN check to `verify_trainer_pin` (so
  it inherits the lockout for free) and returns a signed 12-hour JWT carrying
  `trainer_id` and `role_tier`. HS256, signed **inside Postgres** over pgcrypto's
  `hmac()`, with the project JWT secret held in Supabase Vault. **No Edge
  Function**: no Deno, no `supabase functions deploy`, no second deploy target, no
  function secret to rotate. Everything stays in a migration, which matches how
  this repo works. Also ships `sign_in_front_desk()` (the shared Front Desk seat
  has no `trainers` row, so `sign_in` had nothing to key on and would have been
  locked out of its own app) and `verify_jwt_secret()`.
- **`0005_rls_identity_policies.sql`** - the lockdown. Every policy keys on the
  JWT claims. anon loses all table grants. SELECT/INSERT/UPDATE require a
  signed-in team member; DELETE requires admin; `settings` (which holds the admin
  PIN hash) becomes admin-only, closing a self-escalation path; notifications are
  per-trainer. PIN setters become admin-gated with a `service_role` break-glass
  (without it, admin-only is a deadlock the day every admin forgets their PIN).
- **`trainer_directory` view** - the chicken-and-egg fix. You must pick your name
  before you can have a token, but you cannot read `trainers` without one. A
  definer view exposing names only. It is the single thing anon may read anywhere
  in the database. Includes the legacy `role` column deliberately: omit it and the
  pre-auth roster load hydrates every profile with `role='trainer'`, and the next
  Manage Team save silently downgrades every admin.
- **`0006_kiosk_public_writes.sql`** - restores the two public member tiles with a
  write-only identity. `sign_in_kiosk()` mints a 30-minute token with
  `role_tier='kiosk'`. **The load-bearing line:** `app_is_signed_in()` is
  redefined to mean "signed in AS A TEAM MEMBER"
  (`trainer_id IS NOT NULL AND role_tier <> 'kiosk'`). Every policy in 0005 keys
  on that function, so all of them - every SELECT, UPDATE and DELETE - stop
  applying to the kiosk instantly, without editing a single policy. Exactly two
  permissive INSERT policies are added back (`wros`, `clients`). A kiosk that
  sends an existing row id is still safe: ON CONFLICT DO UPDATE then evaluates the
  UPDATE policy, the kiosk has none, and the write is rejected.
- **`0007_revoke_public_execute_on_pin_setters.sql`** - `REVOKE ... FROM PUBLIC`
  on the PIN setters. See bug 6.
- **`0008_lock_trainer_directory_to_select_only.sql`** - `REVOKE ALL` +
  `GRANT SELECT` on the roster view, and `ALTER DEFAULT PRIVILEGES` so future
  objects do not inherit anon write access. See bug 7.

**App**

- Token injected via a custom `global.fetch` (not `rest.headers`, which silently
  does nothing - see bug 3).
- `realtime.setAuth()` on every auth change. Realtime enforces RLS **separately**
  from REST; miss this and `notifications` / `trainer_time_off` (the only two
  tables in the supabase_realtime publication) silently stop delivering with no
  error anywhere.
- `loadAll` re-runs on auth flip and has a pre-auth path: signed out, only the
  roster is reachable, so the app shows the login screen instead of "Couldn't
  connect to the server."
- The pre-auth path hydrates all thirteen dirty-check refs (see bug 4) and doubles
  as the sign-out flush.
- Sign-out clears the token centrally in `setSession`. There are a dozen
  `setSession(null)` call sites; leave the token behind at any one of them and the
  next person to pick up the iPad inherits the previous user's database credential
  for up to 12 hours.
- 12-hour token expiry watchdog. An iPad left signed in overnight would otherwise
  keep rendering as signed-in while every read returned empty and every write was
  rejected with no error the user ever sees - a trainer could log a whole morning
  of sessions into a void.
- `isStaff()` (not "do we have a token") gates the loaders, so the kiosk takes the
  pre-auth path and never tries to read tables it cannot see.
- Both PIN setters now handle a new `forbidden` status.

**Pipelines**

- Both importers cut over to `SUPABASE_SERVICE_ROLE_KEY` in their scheduled-task
  wrappers (gitignored). They already preferred it and fell back to anon, so this
  was a one-line change each.

### Test results

- `node --check` on the embedded JS - PASS
- **Five-seat verification against a real Supabase branch**, and the three team
  seats re-verified in a real browser:

  | | stranger | kiosk (member) | trainer | admin |
  |---|---|---|---|---|
  | read clients | DENIED | DENIED | yes | yes |
  | write clients | DENIED | INSERT only | yes | yes |
  | submit a WRO | DENIED | yes | yes | yes |
  | delete a client | DENIED | DENIED | DENIED | yes |
  | read admin PIN hash | DENIED | DENIED | DENIED | yes |
  | reset a PIN | forbidden | forbidden | forbidden | yes |
  | sign-in roster | yes | yes | yes | yes |

  A member submits an orientation request at the kiosk and a trainer then sees it.
  The workflow survives intact while the kiosk reads nothing.
- `sign_in` with a wrong PIN returns `wrong` and issues no token - PASS
- Lockout: 5 failures returns `locked`, and a *correct* PIN while locked still
  returns `locked` (it does not leak) - PASS
- Deploy verified on the live production site, signed out:
  `clients` BLOCKED, `leads` BLOCKED, anon write BLOCKED, roster 17 names - PASS
- Import pipelines proven with a live authenticated read:
  `SERVICE_ROLE: read 15 clients` / `ANON: blocked` - PASS
- Supabase security linter: zero `rls_disabled_in_public` errors. Remaining
  notices are deliberate (deny-all tables; login RPCs that must be anon-callable).
- Tagged v4.46 before push per tag-on-release.

### Deferred

- **Row ownership.** Any signed-in trainer can still update any client's row.
  Structural: sessions, packages and attendance live inside JSONB on the parent
  row (ADR-0004), so RLS cannot distinguish "log a session" from "edit someone
  else's client." Intra-team boundaries stay in `ctx.can()`. Acceptable for an
  internal team tool; it was never acceptable for the open internet, which is what
  this pass closes.
- **Class structure edits.** Marking attendance and editing class structure are
  both UPDATE on the same row, so RLS cannot tell them apart. Structure-edit
  remains an app-side `ctx.can()` gate.
- Anon key rotation (hygiene now, not urgency).
- Retire `rls_staging_test.py` in favour of `rls_identity_test.py`.
- README + ADR refresh for both auto-write pipelines.

### iPad test checklist for v4.46 specifically

- Load the site signed out. The trainer name list appears (that is
  `trainer_directory`). Open devtools and query `clients` - expect a permission
  error. **If that returns client data, the lockdown failed. Roll back.**
- Sign in with a PIN. Wrong PIN five times trips the lockout toast, and the
  *correct* PIN still says locked until it clears.
- Log a PT session, sign it, reload. It survives.
- Tap "Weight Room Orientation Sign-Up" as a member, submit the form, then sign in
  as a trainer and confirm the WRO appears on the board.
- Drop a class for sub coverage on one iPad, claim it on a second (confirms
  realtime is still authorized).
- As a non-admin, try to delete a client. The app blocks it and so does the
  database.
- As an admin, change a team member's PIN in Manage Team, then sign in with it.
- Leave an iPad signed in overnight. Next morning it should ask for the PIN again
  rather than silently failing every write.

### The lesson

Seven separate failures, and not one was caught by reading the code. The
`allow all` policies would have made RLS purely cosmetic while the linter went
green. The crypt bug would have locked the whole team out with no way back. My own
pre-auth path would have written empty arrays over live client records. The kiosk
regression would have been discovered by a confused member, not a log file. And
0007 was found by a linter *after I had told Reagan it was already fixed*.

And the last one, bug 7, is the sharpest of all: it was found AFTER the work was
declared finished, verified, shipped, documented and pushed - during a final audit
that existed only because the ask was "make sure this is correctly done." The
policies were all correct. The GRANTS were not, and nothing about a policy review
would ever have surfaced that.

Run it. Then check what actually happened. Then check the thing you did not think
to check. Assertions - including confident ones, including mine - are not
evidence.

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
