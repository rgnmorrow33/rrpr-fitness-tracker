# Backlog - Round Rock Fitness Tracker

Deferred work: cleanups, refactors, and unbuilt features. Load on demand -
this is not session-critical context, which is why it does not live in
CLAUDE.md.

Consolidated 2026-07-07 from three previously-overlapping lists: CLAUDE.md's
"Deferred cleanup pile" and "Deferred features," and ARCHITECTURE.md section 9
"Known refactor targets." One list now, deduplicated.

Convention (same as the rest of `/docs`): no line-number references - the
single-file app drifts. Anchor to function names, section names, or search
strings.

## Unbuilt features

Not built; not a priority right now.

- Goal tracking for PT clients (high-value, ties to council-email pipeline)
- Discharge questionnaire automation
- Recurring class series enrollment for planned programs
- PAR-Q / health screening gate
- Class capacity hard-block (currently soft-warn only)
- Trainer-to-trainer messaging/notes
- Admin role-based PIN access
- PDF reporting (CSV only for now)
- Email/SMS notifications

## Major architectural

- **JSONB sessions to normalized table.** Per ADR-0002, sequenced via
  ADR-0003 Phase 2C. The largest single architectural shift queued. ~8 to 12
  weeks of work, gated on Phase 2B foundation completing.
- **Single-file decomposition.** Posture and decomposition criteria captured
  in ADR-0005; execution sequenced via ADR-0003 Phase 2B. Extract the storage
  adapter, translators, and at least one major view into separate files served
  via Netlify. ~4 to 6 weeks. Doesn't need to finish in Phase 2B, but needs to
  start with a coherent pattern.
- **Schema migration discipline.** Version-controlled SQL in `/sql/migrations/`
  with timestamped names. Today the only file in `/sql` is
  `wipe_pre_alpha_clients.sql`, a one-time data wipe. Phase 2B blocker.
- **Backup / restore drill.** Documented runbook, tested at least once.
  Phase 2B blocker.
- **Smoke test harness (persist-class coverage).** A suite that catches the
  green-then-red toast/persist class of bug for the most-trafficked entities.
  Note: a post-deploy liveness/render smoke now exists
  (`.github/workflows/smoke.yml`); this entry is the remaining gap -
  persist-correctness coverage, not liveness. Phase 2B blocker.

## Operational documentation gap

Operational documentation currently lives in Reagan's project context (the
Update Log .docx file and the Sprint Status doc). Migration of these into
`/docs` as committed artifacts is queued. Until that happens, the canonical
version-by-version history and the live sprint backlog are not visible to
anyone who doesn't have direct access to Reagan's files.

## Security hardening (deadline-bound)

- **Anon RLS posture.** Per *anon RLS prototype posture* (ADR, proposed). RLS
  is disabled across all public tables; the committed anon key is the only
  gate. Tighten before APC opens (April 2027) or before any clinical PHI flows
  through the system, whichever comes first.
- **PIN hashing.** Per *PIN storage as plaintext* (ADR, proposed). The PIN in
  the settings table is plaintext today. Hash before APC.

## Deferred cleanup pile

Address in a dedicated cleanup commit when convenient. These are their own
pass - do NOT touch app code for them mid-feature.

- **`classes` duplicate/legacy column drift** (Pattern-A-class: duplicate
  columns that cause silent translator rejections; surfaced during the v4.32
  SCHEMA.md NEW-flag fill):
    * `classes.instructor` vs `classes.instructor_name`. The live column is
      `instructor` (written as passthrough, read everywhere).
      `instructor_name` has zero code refs - an unwired duplicate. Drop
      `instructor_name` in a future migration.
    * `classes.time` vs `start_time` / `end_time`. `time` is never written
      (`translate.classes` maps `startTime` / `endTime` only) and is read only
      as a legacy fallback (`c.startTime || c.time`) for pre-split rows.
      Candidate to drop once no live row relies on the fallback.
- **Trainers replace-all on save.** Every save sends the full profile array.
  A diff-based save would send only changed rows. Add only if Supabase rate
  limits surface.
- **Self-write originator filter for sub events.** The subscription echoes our
  own writes back. The existing dirty-check filter handles the no-op; a true
  originator id would be cleaner.
- **Channel auto-reconnect on subscription drop.** If subs actually drop in
  production it's a P1 to investigate, not cleanup.
- **Lead expanded perms** (`canEditAnyAttendance`, `canEditAnySession`) are
  unscoped. Future work: scope to a reporting tree once we have one.
- **Phantom `claimed` sub_assignments.** If the sub_request flow ever leaves
  orphaned claimed entries, write a one-time cleanup query.
- **Pattern B audit (Patch G2 scope).** Most ctx mutators are fire-and-forget
  `setX` with the global `_saveIfDirty` useEffect handling async persistence
  (`upsertClient` / `auditedUpsertClient`, `upsertClass` / `auditedUpsertClass`,
  `addSession`, `addAttendance`, `addCancellation`, `addSubAssignment`,
  `upsertContact`, `upsertReferral`, `upsertWRO`, `addClosure`, etc.). Their
  callers fire green toasts before the save resolves, so a translator/schema
  mismatch on any of them surfaces as the "green then red" bug pattern (the
  one Patch P fixed for leads). G2 should sweep them with the `requestTimeOff`
  / `createQueueEntry` persist-then-toast shape.
- **`fmtRange` duplicated in two places.** Local copies in `TimeOffManagerModal`
  and in `TimeCardView` (from Sprint O Phase 2). Lift to module scope on a
  future cleanup pass.
- **`.pill-btn` CSS rule scoped to `.audit-controls`.** Usage outside that
  container (in `AuditView`, and any future site) renders with browser defaults
  plus inline overrides. The `ConsultQueueView` filter-pill normalization
  (Sprint P Tier C1) was deferred here. Resolution options: (a) unscope the
  `.pill-btn` selector (touches shared CSS), or (b) wrap all `.pill-btn` usages
  in `.audit-controls` consistently. Defer until a sprint can opt into
  shared-CSS work.
- **`clients.packages[]` field-shape drift in SCHEMA.md.** The documented shape
  lists fields that aren't actually stamped on package rows:
    * Template-only fields documented as row fields: `location`, `is_pairs`,
      `is_consult`, `is_intro`, `validDays`. These live on
      `PT_PACKAGES_BY_FACILITY` template entries only; `AddPackageModal` and
      the bulk import don't copy them onto the row. `getPackageMeta(p.type)` is
      the operative read path for any consumer that needs them.
    * Soft-delete fields documented in camelCase (`deletedAt` / `deletedBy` /
      `restoredAt` / `restoredBy`). Actual stamping is snake_case (`deleted_at`
      / `deleted_by`, via `softDeletePackage` / `hardDeletePackage`);
      `restoredAt` / `restoredBy` are never stamped - `restorePackage` just
      nulls the `deleted_at` / `deleted_by` pair.
  Fix: rewrite the SCHEMA.md `clients.packages[]` field list to the
  actually-stamped shape; move template-derived fields to a "derived from
  template via `getPackageMeta()`" note; correct the soft-delete fields to
  snake_case and remove the never-stamped `restoredAt` / `restoredBy` entries.
- **Sprint P Tier C2-aligned strays.** Redundant inline modal `maxWidth`
  overrides (the `.modal` CSS default is already 560px), sibling `foldLinks`
  `fontSize` inconsistencies (some still 12px vs the 13px `.section-head .meta`
  match), `NewQueueEntryModal` validation `var(--red)` usages (`errors.phone` /
  `errors.email` plus their borderColor counterparts), and `ConsultQueueView`
  aged-row `var(--red)` instances (the border ternary and the AGED badge
  background). Mechanical sweep, ~10 edits total. Bundle in a future
  admin-polish cleanup commit.

## Notification UX followups

- Tier-specific notification behaviors (filter chips, a dedicated full-list
  view, time bucketing, grouping rollups).
- Front Desk admin notification scope: either give Front Desk a synthetic
  `trainer_id` row in `trainers`, or route Front Desk into a separate
  notification queue. See ARCHITECTURE.md section 4 for the gap.

## Subscription performance

- The per-entity realtime debounce is set at 100ms. Tuning may be needed if
  multi-trainer activity bursts surface stale-state windows.

---

## Resolved / removed (audit trail)

- **SCHEMA.md and ARCHITECTURE.md line-number drift** (was in CLAUDE.md's
  Deferred cleanup pile). Dropped 2026-07-07 as obsolete: both docs now carry
  zero `RoundRock_Fitness_Tracker.html` line-number references (verified by
  grep), so the sweep that entry called for has already happened. The
  going-forward "no line-number references in docs" convention lives in
  CLAUDE.md's Working conventions.
