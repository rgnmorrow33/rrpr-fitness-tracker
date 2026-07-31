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
- Microsoft Forms -> Supabase intake ingestion. Writes the
  `clients.intake_paperwork` JSONB object that the v4.40 read-only render
  (`INTAKE_SECTIONS` in ClientDetail) displays. Until built, intake packets
  land via import/SQL only. Flagged as an unresolved gap during the Section 5
  PT-clinic integration review; separate build, do not fold into a render fix.
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

**Partly closed.** The update log migrated into `/docs` and
`docs/Fitness_Tracker_Update_Log.md` is now canonical and version-controlled.

What is still open, and it bit on 2026-07-29: **the old
`Fitness_Tracker_Update_Log.docx` copies still exist outside git**, several of
them in the Claude project, and a spec got written against one that was three
versions behind. Following it literally would have written duplicate v4.47 and
v4.48 entries into the canonical file. Delete those copies or stamp them
clearly as point-in-time snapshots. See the preflight rules at the top of
CLAUDE.md.

The Sprint Status doc is still outside `/docs` and unmigrated.

## Security hardening (deadline-bound)

Both original entries here - anon RLS posture and PIN hashing - **closed in
v4.46** and were moved to the audit trail at the bottom of this file on
2026-07-29. What is left is the part v4.46 did not solve:

- **Row-ownership enforcement.** RLS is on, but any signed-in trainer can
  update any client's row. Structural rather than lazy: sessions, packages and
  attendance live inside JSONB on the parent row (ADR-0004), so "log a session"
  IS "UPDATE the whole clients row." Unwinding it is gated on the ADR-0002 /
  ADR-0003 Phase 2C normalization. Acceptable for an internal team tool;
  revisit before APC opens (April 2027) or before any clinical PHI flows,
  whichever comes first.
- **Rotate the anon key** pasted into chat on 2026-07-10. Hygiene, not urgency:
  the key ships to every browser regardless, and RLS is what makes that safe.

## Open correctness questions

Not cleanup. Each one changes numbers on live records, so each needs its own
version and its own decision rather than a convenient sweep.

- **`sessionConsumption` counts `scheduled` sessions as consumed.** Only
  `excused` returns 0; every other status, including `scheduled`, deducts at
  its duration ratio. So a booked-but-unsigned future session reduces
  `sessionsRemaining` exactly like an attended one. Blast radius is everything
  downstream of `sessionsRemaining`: the `sweepExpiringPackages` early exit
  (`remaining <= 0` skips the client entirely, so a genuinely expiring package
  can go unnotified), the `sessions_low` bands, `isClientCold`,
  `clientPackageFlags`, the `expiring` refinement in `clientLifecycleStatus`,
  and the remaining-session count a trainer reads on screen. Surfaced v4.50
  while measuring lifecycle buckets against live data: one live client reads
  cold and stale purely because her most recent session row is a `scheduled`
  booking. Deciding this means deciding whether a booking is a claim on the
  package or only a sign-off is - do not fold it into a feature batch.
- **Should lead ever be able to permanently delete a WRO or a referral?**
  v4.57 gated `deleteWRO`/`deleteReferral` to `canHardDelete` (admin-only),
  which matches what the `wros`/`referrals` DELETE RLS policy
  (`app_is_admin()`) already enforced - a lead-tier delete was already refused
  server-side before v4.57, it just refused silently and reported success. So
  v4.57 didn't take away a working capability, it stopped lying about one.
  Whether lead *should* get real delete rights here is a policy question,
  needs an RLS migration, and was deliberately kept out of v4.57. Same shape
  as the lead "own team" scoping TODO below - both are "lead permissions are
  provisional this cycle" questions.

## Deferred cleanup pile

### From v4.57 (delete hardening)

- **`deleteCancellation`, `removeSubAssignment`, `deleteContact` are dead
  code.** All three are exported on `ctx` with zero UI callers (confirmed by
  grep across the whole file). `removeSubAssignment` is a stale near-duplicate
  of the live `deleteSubAssignment`. Left out of the v4.57 guard/audit sweep
  on purpose - adding a permission guard to unreachable code would misleadingly
  imply they're live. Candidates for removal in a dedicated cleanup version;
  removal, not a guard, is the fix.
- Stray `/* ===== PIN MODAL ===== */` section marker above the KIOSK WRO INTAKE
  block; the comment appears twice and the first one labels the wrong section.

### From v4.55 (build version indicator)

- **Pre-push hooks check the wrong worktree's HEAD when run from inside a
  worktree.** `pre-push-syntax-check.js` and `pre-push-tag-check.js` both
  resolve their project root via `CLAUDE_PROJECT_DIR` (falling back to
  `git rev-parse --show-toplevel`) and then run `git show HEAD:<file>`
  against that root. In a Claude Code session working from an isolated
  worktree, `CLAUDE_PROJECT_DIR` stays pinned to the primary checkout for
  the life of the session - so the Claude-Code-PreToolUse invocation checks
  the primary checkout's HEAD, not the worktree branch actually being
  pushed. Surfaced directly while proving Fix C: pushing `v4.55` from the
  worktree got BLOCKED with an accurate-looking but wrong-context error
  (it was reading the primary checkout's pre-v4.55 `main`, not the
  worktree's HEAD). The native `--git` mode (the real git pre-push hook,
  which always runs with the pushing repo as cwd) is unaffected - this only
  bites the Claude-Code-side copy of the same check. Every previous
  worktree-based push likely had its syntax/tag check silently validate the
  primary checkout's branch instead of the one being pushed, not a new
  bug from this version.

### From v4.53 (lead delete)

- `makeEntity.save` early-returns when the array is empty, so emptying any
  entity list persists nothing at all. Same class of bug as the v4.53 lead
  delete, wider surface: it applies to every entity, not just leads.
- `activeQueue` filters on `q.deleted_at`, a column the `leads` table does not
  have. Dead filter. Harmless today, misleading to read, and it will quietly
  start working if anyone ever adds the column.
- Multi-device resurrection: an iPad holding a stale entity array can re-upsert
  a row another device deleted, on its next dirty save. Pre-existing for every
  entity. The v4.53 fix advances `queueRef.current` on the deleting device
  only.
- A hard-deleted lead leaves no record anywhere. If a deletions log is wanted
  it is its own version, not a rider on a fix.
- The lead Delete button has no in-flight guard. A double tap fires two
  deletes and the second reports that it did not land.
- `clients.from_queue_id` has no foreign key to `leads.id`. v4.53 guards the
  one delete path in the app; nothing guards SQL or the importers.

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
- **Date-helper disambiguation comments reference call sites by line number.**
  The comment blocks above `addDays`, `addDaysYMD` and `daysBetween` point at
  each other numerically. The no-line-numbers convention at the top of this
  file is scoped to `/docs`, so these are not a violation, but the same
  reasoning applies harder inside the single file that actually drifts - the
  v4.50 diff moved two of the three within hours of the comments landing.
  Rewrite as name-only cross-references.
- **`.gitignore` does not cover the untracked files that trip `release:tag`.**
  `AUDIT_FINDINGS.md`, `playwright.local.config.ts`, `tests-local/` and
  `tests/trainer-smoke.spec.ts` sit untracked in the working copy, so the
  tag helper refuses on a dirty tree and every release needs `--allow-dirty`.
  Open since v4.45. The `.gitignore` commit is the real fix.

## Notification UX followups

- Tier-specific notification behaviors (filter chips, a dedicated full-list
  view, time bucketing, grouping rollups).
- Front Desk admin notification scope: either give Front Desk a synthetic
  `trainer_id` row in `trainers`, or route Front Desk into a separate
  notification queue. See ARCHITECTURE.md section 4 for the gap.

## NEEDS VERIFICATION ON A REAL DEVICE

Open questions that code review cannot settle. Each one names the exact check
that answers it. Do not close any of these by reasoning about them.

The Selisa-facing version of these lives in `docs/DEVICE_CHECKS.md` - same checks,
written to be run by someone who is not going to read this file. Keep the two in
sync: when a check passes there, close it here.

- **P1 - Are pre-auth realtime channels re-authorized on sign-in?**
  (opened 2026-07-14, v4.48)

  The realtime useEffect has `[]` deps, so it mounts once while signed OUT and
  opens all 4 entity channels (clients, classes, leads, trainer_time_off) as
  **anon**. Since v4.46, RLS denies anon on every one of those tables.
  `realtime.setAuth()` fires on the auth flip and SHOULD re-authorize the joined
  channels. Nobody has confirmed that it does.

  If it does not, **live cross-device sync has been silently dead since the
  v4.46 flip.** The app would look completely fine: data still converges via
  reload, mount-fetch, and the wake sweep. Two trainers on two iPads would just
  never see each other's changes in real time, and nothing would log an error.

  This is not theoretical. All three of clients/classes/leads ARE in the
  supabase_realtime publication (verified 2026-07-14), so they are supposed to
  push live.

  THE CHECK: drop a class for sub coverage on one iPad. It must appear on a
  second, already-open iPad **without reloading it**. If it only appears after a
  reload, channels are not re-authorizing.

  THE FIX IF IT FAILS: add `authVersion` to the realtime useEffect's dependency
  array so channels are torn down and reopened WITH a token on the auth flip.
  Note this changes channel lifecycle and interacts with the `_activeChannels`
  reconnect registry - plan it, do not patch it blind.

---

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
- **Anon RLS posture** (was Security hardening, deadline-bound). Closed by
  v4.46, verified 2026-07-29: RLS enabled on all 19 public tables, 55
  policies, zero `allow all`, and anon reduced to a single privilege
  (`trainer_directory:SELECT`) by migration 0008. The *anon RLS prototype
  posture* ADR is superseded.
- **PIN hashing** (was Security hardening, deadline-bound). Closed by v4.46
  migration 0002, verified 2026-07-29: PINs are bcrypt and verified
  server-side via `verify_trainer_pin` / `verify_admin_pin`. `trainers.pin` is
  NULL on every row and `settings.admin_pin` holds a hash. PUBLIC execute on
  the setters was revoked in 0007. The *PIN storage as plaintext* ADR is
  superseded.
