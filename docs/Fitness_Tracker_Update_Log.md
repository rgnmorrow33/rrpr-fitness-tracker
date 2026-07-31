# Round Rock Parks and Recreation - Fitness Tracker Update Log

**Live version: v4.57** (delete hardening: permission guards on every delete
handler, undo instead of a confirm on attendance/session deletes, four
ghost-deletes made real, hard-delete rename). Merged to `main` and deployed
July 31, 2026. Tag `v4.57` points at `356a6b7` on `main`.

Newest version at the top; append new sections above the older ones.

> Canonical running log, version-controlled in `docs/`. It previously lived only
> as a Word doc outside git and drifted (a stale v4.29 copy caused confusion on
> July 10). Keep it here going forward. `npm run log:scaffold` produces the raw
> material (SHAs, diff stats, file lists) for new entries.

---

## Current standing - July 31, 2026

- **Live version: v4.57**, tagged `356a6b7` on `main` and deployed. Netlify
  prod (pardfitnesstracker2) deploys on push to `main`. `node --check` on the
  embedded JS: PASS, verified independently of the pre-push hook because v4.57
  was built in an isolated worktree and `BACKLOG.md` documents that the
  Claude-side hook resolves through `CLAUDE_PROJECT_DIR` and checks the wrong
  branch in that case.
- **v4.57 shipped from a branch and briefly carried an off-main tag.** Code was
  committed as `393feb6` on `worktree-delete-hardening-v457` and tagged there,
  which meant `git tag | tail -3` reported v4.57 while `main` sat at v4.56. Two
  of the three signals in the version-confirmation ritual were wrong for about
  two hours. The tag was withdrawn from local and origin, the branch was
  fast-forwarded into `main`, and v4.57 was re-tagged on `main`.
- **The pre-push hook caught the re-tag ordering and was right to.** A push of
  `main` was refused with "commit(s) in origin/main..HEAD reference version(s)
  with no git tag: v4.57". Tag first, then push the branch, then push the tag.
  Worth remembering: the hook enforces tag-before-push, so any plan that defers
  tagging until after the deploy will be blocked.
- **v4.57 shipped with zero device verification.** Nothing in it has been
  exercised by a human against the running app. `Tracker_Verification_v4_57_v1_1`
  is the packet that closes that, and `DEVICE_CHECKS.md` Checks 7 to 11 are the
  canonical version of those steps.
- **v4.57 closed the delete-hardening gaps a Phase 1 diagnostic found across
  the app.** Every delete handler now gates at the handler, not only the
  render (a hidden button with an ungated handler was the dangerous case -
  `deleteAttendance` had neither, and was reachable for any trainer on any
  class since `ClassDetail` entry turned out to be unrestricted). Attendance
  and session deletes drop their `window.confirm` in favor of an undo toast
  (8s window) - fewer taps for the normal case, one tap to reverse a mis-tap
  on a shared iPad. The attendance audit payload widened (was missing `time`
  and `logged_at`, and collapsed `instructor`/`actualInstructor`). Four
  ghost-deletes (`deleteWRO`, `deleteReferral`, `deleteItem`, `removeTrainer`)
  that only filtered local state and never issued a DELETE - same shape as the
  v4.53 lead-delete bug - now do a real `DELETE` with a row-count check and a
  shared type-to-confirm prompt; `removeTrainer` also refuses outright instead
  of just warning when the trainer has assigned clients or classes.
  `persistBannerDelete` got the same row-count check `deleteQueueEntry`
  already had. `deleteClient`/`deleteClass` renamed to `hardDeleteClient`/
  `hardDeleteClass` - the old names read backwards from what they did.
  `deleteSession` now applies one rule at all three call sites: a scheduled
  (not-yet-logged) session is deletable by anyone who can see it, anything
  else needs `canDeleteSession` - previously the three call sites disagreed
  with each other. `deleteCancellation`, `removeSubAssignment`, `deleteContact`
  are dead code (zero UI callers) and were deliberately left unguarded rather
  than misleadingly "fixed" - see BACKLOG.md.
- **v4.56 added youth weight room certification as a third member-facing
  kiosk tile** and brought both member-facing forms in line with the live
  Microsoft Forms questionnaires. Certifications ride the `wros` table behind
  a `formType` discriminator in the existing `data` jsonb - no migration, no
  new RLS policy, and the kiosk token's existing INSERT grant on `wros`
  (migration 0006) already covers it. They stay out of the WRO volume and
  conversion numbers and get their own filter, stat card and CSV columns.
- **The adult WRO form is now a superset of the online questionnaire**, not a
  different set of questions. It gained emergency contact (required),
  preferred day, preferred times and areas of interest, and went 6 steps to 7.
  The goals / experience / health-flag / follow-up steps that feed the
  specialist prep and the conversion metrics were kept rather than traded away.
- **The Fitness Pre-Assessment packet needed no shape change.** All 38
  questions on the July 2026 PDF still map onto intake-v2 field-for-field with
  no additions, removals or type changes, so `intake_paperwork` and the Power
  Automate template are untouched. The only drift was render order, corrected.
- **v4.55 shipped on July 30 but was never logged.** Entry reconstructed below
  from commit `e2ca0a8` on July 31. The header of this file read v4.54 for a
  day while the tracker footer read v4.55 - exactly the drift
  `CANONICAL-SOURCES.md` exists to stop, and the v4.55 pre-push version-match
  check does not catch it because it compares `APP_VERSION` to the file footer,
  not to this log.
- **v4.54 made every class write a trainer can reach actually land.** `classes`
  is the only table in the database whose RLS is asymmetric - INSERT admin-only,
  UPDATE open to any signed-in trainer - and every class write in the client was
  a PostgREST `.upsert()`, which is `INSERT ... ON CONFLICT`. Postgres evaluates
  the INSERT `WITH CHECK` even when the conflict resolves to an UPDATE, so a
  trainer updating a class they already own was refused. Attendance, sub
  requests, sub claims, cancellations and the time-off auto-post were all
  affected and all toasted success anyway.
- **v4.53 made lead delete write.** The handler dropped the row from React
  state and issued no database call, so the array save upserted the survivors,
  realtime echoed, and the app refetched the "deleted" lead back in. Now a
  real `DELETE` whose returned row count is checked, admin-gated at the
  handler, and refused outright when a client points at the lead.
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
- **All device checks in `docs/DEVICE_CHECKS.md` are still OPEN**, 6 before v4.57 and 11 after, including
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

## v4.57 - July 31, 2026

Delete stops being three inconsistent things. Every handler gates at the handler,
attendance and session deletes become undoable instead of confirm-gated, and four
buttons that never issued a database call start issuing one.

### Trigger

Reagan asked whether deleting should be harder, and separately suspected trainers
could delete things they should not. A read of the live RLS posture plus every
delete call site found the first half of that unfounded and the second half worse
than described.

### Goal

A delete either cannot happen, can be undone, or is unmistakably deliberate. It
never reports success when the write did not land.

### File version

v4.57 - 32,601 lines, 1.5 MB (`RoundRock_Fitness_Tracker.html`)

### What the diagnostic found

Verified against live on 2026-07-31, not inferred: every DELETE policy on all 14
policied tables is `app_is_admin()`, reading the `role_tier` claim off the JWT.
Five more tables carry RLS with zero policies. **No trainer can hard-delete any
row.** The original worry, as stated, was unfounded at the database layer.

The damage was not DELETE-shaped. `sessions`, `attendance`, `cancellations`,
`subAssignments` and `packages` live as JSONB arrays on `clients` and `classes`,
so removing one is a whole-row UPDATE and both tables carry `upd_signed_in`.
Auditing delete policies gave false comfort for exactly that reason.

Three specific findings:

- **The attendance hole was the wide version.** The delete control was rendered
  unconditionally with no handler check, and `ClassDetail` turned out to be
  reachable for any class by any trainer through TrainerGX "Full schedule"
  browse mode, whose card `onClick` calls `setDetailId(c.id)` with no ownership
  check. This closes the open question from the July 29 beta verification pass,
  which could only call it a proximity pointer.
- **Only two real `.delete()` calls existed in 32,330 lines.** Five handlers
  filtered React state and issued nothing, riding one generic upsert-only entity
  factory with no delete path. Same shape as v4.53.
- **The attendance audit entry could not reconstruct the row it recorded.** It
  dropped `time` (payroll-relevant) and `logged_at`, and collapsed `instructor`
  with `actualInstructor`, losing the distinction on a sub-covered class.

### What shipped

- **Fix A.** Shared `guardDelete()` plus `DELETE_DENY_MSG`, called as the first
  statement of all 13 live delete handlers. Render gates untouched; this is a
  second layer, on the premise that a hidden button with an ungated handler
  counts as ungated. `deleteQueueEntry` was already correct and left alone.
- **Fix B.** `toast(msg, kind, opts)` gained an optional action button, additive
  and backward compatible across all 222 existing call sites. Attendance and
  session deletes drop `window.confirm` for an 8-second Undo toast that
  reinserts at the original array position through the same audited path.
  Attendance audit payload widened. `deleteSubAssignment` gained an audit entry.
- **Fix C.** `deleteWRO`, `deleteReferral`, `deleteItem` and `removeTrainer`
  issue a real DELETE with a row-count check. `removeTrainer` refuses outright,
  rather than warning, when the trainer has assigned clients or classes.
  `persistBannerDelete` got the row-count check it was missing.
- **Fix D.** `confirmTypedDelete()` extracted from two byte-identical
  `doHardDelete` copies and applied to all six irreversible sites.
- **Fix E.** `deleteClient` / `deleteClass` renamed to `hardDeleteClient` /
  `hardDeleteClass`. The old names read backwards from what they did, since
  `softDelete*` is what the visible Delete button calls.

### Decisions of record

- **D1.** `deleteSession` normalized up, not down. Three call sites had three
  behaviors. One rule now: a `scheduled` session is deletable by anyone who can
  see it, anything else needs `canDeleteSession`. Normalizing down would have
  pulled a working affordance at the highest-traffic surface during beta week.
  The trainer roster is the only route into `ClientDetail` at trainer tier, so
  the ownership check was verified redundant and skipped.
- **D2.** WRO and referral delete are admin-only now, which restricts lead.
  Accepted because the button already did not work for Carlos: RLS refused a
  lead-tier delete silently. This stops the lie rather than removing a
  capability. Letting lead genuinely delete them is an RLS policy change and a
  separate decision. WRO records carry a signed liability waiver.
- **D3.** `deleteCancellation`, `removeSubAssignment` and `deleteContact` are
  dead code with zero UI callers. Left unguarded and not removed. Guarding
  unreachable code would imply it is live and mislead the next reader. Logged
  in `BACKLOG.md` for a dedicated cleanup version.
- **D4.** `removeTrainer` keeps a handler guard despite a real render gate, on
  the same premise as Fix A.

### Design position

Ceremony tracks reversibility, not the word "delete." A password or second PIN
prompt was considered and rejected: the 24-hour TTL re-prompt is already a
confusion source, and a PIN does not stop a mis-tap on a shared iPad. Soft delete
on the JSONB array items was also rejected, because the cost is sweeping every
read site (timecards, headcount, metrics, session consumption, package balance,
CSV export), not storage.

### iPad test checklist for v4.57

- Sign in as a trainer, open any class you do not teach, and look at Session
  History. **There should be no delete control next to the attendance rows.** If
  there is one and it works, Fix A did not take.
- As a lead or admin, delete an attendance record. It should vanish with an
  "Undo" toast. **Tap Undo. The row should come back where it was.**
- Delete an attendance record and let the toast expire without tapping Undo.
  Reload. It should stay gone.
- As a trainer, delete one of your own not-yet-logged scheduled sessions. It
  should work. Then try a completed one. It should not be offered.
- As an admin, delete a throwaway WRO. It should ask you to type the name.
  **Reload after. If it comes back, Fix C did not take.**
- Sign in as a lead and confirm the WRO and referral Delete buttons are gone.
- As an admin, try to remove a team member who has clients assigned. It should
  refuse and say why, not warn and proceed.

### The lesson

Auditing the DELETE policies was the obvious move and it produced a clean bill of
health that was wrong. On a schema that keeps child records in JSONB arrays on a
parent row, the destructive operation is an UPDATE, and no amount of reading
delete policies will surface it. When asking "who can destroy this data," ask
what shape the write is, not what the button is called.

---

## v4.56 - July 31, 2026

Youth weight room certification shipped as its own member-facing kiosk tile, and
both member-facing forms were reconciled against the live Microsoft Forms
questionnaires they are supposed to mirror.

### Trigger

Reagan supplied July 2026 PDFs of all three live forms - CMRC Weight Room
Orientation Questionnaire, CMRC Youth Weight Room Certification Questionnaire,
and the Fitness Pre-Assessment Packet - and asked for a certification button
plus the other two brought into line.

### Goal

A guardian can request a youth certification at the iPad without a member of the
team standing there. What the iPad asks matches what the online form asks. The
WRO conversion metrics do not silently absorb certification volume.

### File version

v4.56 - 32,330 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### Where the certification data lives

On `wros`, tagged `formType: 'youth_cert'` inside the existing `data` jsonb.

This was the load-bearing call. The alternative was a `youth_certifications`
table, which costs a 0010 migration, a fresh anon/kiosk INSERT grant, a new
storage entity plus translator, and a new list view - and ships nothing until
the SQL has been run by hand. The JSONB split on `wros` exists precisely so the
form can evolve without migrations (SCHEMA.md), and a certification is
structurally a WRO: same claim and release lifecycle, same specialist post-form,
same trainer hour credit, same convert-to-client path. The only real differences
are which questions were asked and who signed.

Consequences, all deliberate:

- **Zero SQL.** No migration, no policy change, no PostgREST schema reload.
- **Rows written before v4.56 carry no `formType`.** `isYouthCert()` treats
  absent as adult, so every existing row keeps its current meaning.
- **Youth rows are excluded from the WRO funnel numbers.** "10+ orientations a
  month" and "15% convert to PT" are adult-funnel targets. Folding
  certifications in would inflate one and dilute the other. They are still
  counted in the work queue (Available / In Progress), because a certification
  waiting for pickup is real team work.

### What shipped

**Fix A - youth certification form and kiosk tile.** `NewYouthCertModal`, four
steps: the youth (name, DOB, gender, phone), the guardian (name, DOB, emergency
contact), scheduling and interests (preferred day, preferred times, personal
training interest, areas of interest), guardian signature. `KioskYouthCertView`
mirrors `KioskWROView` including the 8-second auto-return. Third gold tile on the
Login screen. Front desk can also open it from the WRO list via
`+ Youth Certification` for a phone or paper intake.

**Guardian signature is required**, which the online form does not capture. The
adult WRO already requires a member signature and this is a minor, so the
attestation is worth the ten seconds. Stored as `signedBy: 'guardian'`.

**A new session role, `kiosk_youth`.** It mints the SAME 30-minute INSERT-only
token as `kiosk_wro` through `sign_in_kiosk`; the role only decides which form
renders. Four places tested `session.role === 'kiosk_wro'` to mean "a member is
standing at the iPad" - the idle-timeout exemption, `ctxCurrentUserName`, the
top-level view switch, and the session-shape doc comment. Three now go through a
new `isKioskRole()` helper rather than a second string compare, because the
next kiosk flow would have quietly broken all of them again. Note this is
distinct from the existing `isKioskSession()`, which reads the TOKEN's role tier.

**Fix B - the adult WRO form is now a superset of the online questionnaire.**
Added emergency contact (required, matching the online form), preferred day,
preferred times, and areas of interest using the online form's exact option
vocabulary (Circuit Weights / Cardio Equipment / Free Weights / The Yard /
Other) so responses from both channels bucket together in the CSV. Scheduling
became its own step; the form went 6 steps to 7.

The online form's flat "interested in a personal trainer?" yes/no is **derived**
from the existing richer follow-up-interests question rather than asked twice.
Both channels land the same `interestedInPT` key.

Nothing was removed. Goals, experience level, tour interests, health flags and
follow-up interests all stay, so the Health Flags stat card and filter, the
specialist prep, and the conversion analytics keep their inputs.

**Fix C - surfacing.** YOUTH pill on list rows, own filter tab, own stat card
(this month plus all time), youth-aware WRO detail (guardian block, scheduling
block, guardian signature label, and the Goals and Experience block suppressed
rather than rendering "None selected" against questions that were never asked).
CSV export gained Form Type, Gender, Guardian Name, Guardian DOB, Emergency
Contact, Preferred Day, Preferred Times, Interested In PT and Areas Of Interest.
The time card names a completed certification "Youth Certification" instead of
calling every credited orientation a weight room orientation.

**Fix D - Fitness Pre-Assessment packet.** Re-verified field-for-field against
the July 2026 PDF. All 38 questions still map onto intake-v2 with no additions,
removals or type changes, so `INTAKE_SECTIONS`, `clients.intake_paperwork` and
`intake-import/forms_body_template.json` are all unchanged. The only drift was
render order: the live form asks obstacles (Q25) before why-now (Q26) and
past-attempts (Q27). Reordered so a trainer reads the packet in the order the
member answered it. Display order only; no stored data affected.

### Refactor taken on purpose

`checkboxRow` was a closure inside `NewWROModal` and the youth form needed the
identical control. Hoisted to `intakeCheckboxRow` rather than copied, so the two
member-facing forms cannot drift apart visually. Rendering is byte-identical.
`PostWROModal`'s `checkRow` is a different, denser control for the
specialist-facing form and was deliberately left alone.

### Verification

`node --check` on the embedded JS: PASS. Both flows walked end to end in
headless Chromium against a local copy with every Supabase call intercepted, so
nothing touched production:

- Login renders three member tiles.
- Youth flow: all four steps render, Continue is correctly gated at each one
  (empty form, missing guardian fields, missing day/time), the Other free-text
  reveals on selecting Other, Submit is disabled until the guardian signs and
  enables once they do.
- Adult WRO flow: all seven steps render in order, step 1 stays blocked with
  name and phone filled until emergency contact is supplied, step 5 stays
  blocked until day and times are set.
- Zero page errors. Only console output was the expected realtime WebSocket
  failure from the intercepted network.

Not yet verified on a real iPad. Selisa's pass is still the gate on a decision
record.

### Deferred, found on the way

- **A stray `/* ===== PIN MODAL ===== */` section marker** sits directly above
  the KIOSK WRO INTAKE block, so that comment now appears twice with the first
  one labelling the wrong section. Pre-existing, cosmetic, not touched.
- **The kiosk form panel is not centered.** `login-wrap` carries the navy
  background and the inline `maxWidth: '720px'` shrinks the whole wrapper, so
  the navy panel hugs the left edge with page cream to the right of it. Affects
  the adult WRO kiosk view identically and predates this version.
- **`emailParticipant` in `WRODetail` is hardcoded to orientation wording.**
  Unreachable for youth rows today (the youth form collects no email, so the
  Email Member button never renders), which is why it was left alone. It
  becomes wrong the moment youth email is collected.
- **The youth form asks no health questions at all.** That matches the online
  form, and a guardian at a kiosk is the wrong moment for a health-history
  interview, but it means a youth row can never raise a health flag before the
  session. Screening happens in person and lands through the specialist form.

---

## v4.55 - July 30, 2026

**Reconstructed on July 31, 2026 from commit `e2ca0a8`.** This version shipped
and was tagged without a log entry, leaving this file's header claiming v4.54
for a day. The content below is taken from the commit message and diff, not from
memory.

No version string existed anywhere in the app UI, and a trainer running the app
from an iOS home screen tile had no way to force a fresh fetch - no address bar,
no reload button, no pull-to-refresh on a div-scrolled standalone view. Reported
by Victor Leak on July 30 after a device kept exhibiting old behavior post-deploy.

### What shipped

**Fix A.** `APP_VERSION` declared next to `STORAGE_MODE`, the other top-level
config constant, and mirrored onto `window.APP_VERSION`.

**Fix B/D.** The Login screen (the `session === null` pre-auth gate) shows small
low-contrast text reading "v4.55 · tap to refresh" at the bottom. The version
text IS the refresh control, no separate button. Login is shared with the Book a
Consultation flow, but that flow runs behind the standard `.modal-overlay`,
which blocks interaction with what is behind it, and a member tap costs only a
reload with no session and nothing in flight. WRO kiosk sessions never mount
Login at all. On tap: `location.replace(location.pathname + '?v=' + Date.now())`.
`replace` so the stale URL does not accumulate in history, `pathname` rather
than `href` so repeated taps replace `?v=` instead of stacking it, and no
`location.reload(true)` since that flag has been a no-op in WebKit and Chromium
for years.

**Fix C.** `pre-push-syntax-check.js` gained a version-match assertion:
`APP_VERSION` must equal the trailing `/* vX.Y */` footer comment. Blocks on
mismatch AND on failure to extract either value, since a check that cannot read
the file has not passed. It deliberately does not share the syntax check's
fail-open behavior on internal errors.

Docs: `DEVICE_CHECKS.md` gained Check 6 for Selisa, marked UNVERIFIED since it is
only provable on a real iOS home screen tile. `CLAUDE.md` notes the pre-push gate
is now three checks.

`node --check`: PASS. Diff +19/-1 tracker, +47/-2 hook.

**Note for future versions:** this check compares `APP_VERSION` to the file
footer. It cannot catch a missing log entry, which is what actually went wrong
here.

---

## v4.54 - July 30, 2026

A trainer logging attendance could not write to the class. Every class mutation
below admin went out as an upsert, and `classes` is the one table whose RLS
forbids INSERT to trainers while permitting UPDATE.

### Trigger

Reagan logged a test attendance on Victor Leak's class (Victor: `role_tier =
trainer`) at 2:48pm on July 30 and got two toasts at once:

    Attendance logged
    Save classes failed: new row violates row-level security policy for table "classes"

### Goal

A trainer's attendance log, sub request, sub claim and cancellation reach the
database. A write that does not land says so instead of reporting success and
disappearing on reload.

### File version

v4.54 - 31,691 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

`classes` is the only asymmetric row in the policy table:

| table | INSERT with_check | UPDATE using |
|---|---|---|
| **classes** | **`app_is_admin()`** | **`app_is_signed_in()`** |
| clients, leads, wros, referrals, member_contacts, admin_items | `app_is_signed_in()` | `app_is_signed_in()` |
| closures, schedule_versions, announcement_banners, trainers | `app_is_admin()` | `app_is_admin()` |

The asymmetry is correct and deliberate: a trainer should log attendance on a
class, not create classes. The client could not express it. `makeEntity.save`
and `persistClassRow` both write with `.upsert(rows, { onConflict: 'id' })`,
which PostgREST emits as `INSERT ... ON CONFLICT`, and Postgres evaluates the
INSERT `WITH CHECK` against the proposed row **even when the conflict resolves
to an UPDATE**. Every class write by a non-admin was therefore refused, whether
or not the row already existed.

Verified against live before any edit, impersonating Victor inside a
transaction that ended in `RAISE EXCEPTION`:

    plain UPDATE          = OK (1 row visible)
    UPSERT(existing row)  = FAIL[new row violates row-level security policy for table "classes"]

That is the production error string, reproduced exactly.

`addAttendance` only calls `setClasses`, so the failing write was the deferred
`storage.classes.save` array upsert in the `_saveIfDirty` effect. The green
toast fired synchronously next to a handler that returns `undefined` - Pattern
B again, same shape as the v4.53 lead delete.

A second finding along the way: `addAttendanceAsync`, `addSubAssignmentAsync`,
`addCancellationAsync` and `auditedUpsertClassAsync` were all written, all
exposed on ctx, and all dead. Every one of the ten class-mutation call sites
used the sync variant. The persist-then-toast work had been built and never
wired up. Wiring it was necessary but not sufficient, since those helpers route
through `persistClassRow`, which was itself an upsert.

### Changes

**Fix A - `persistClassRow` writes a real UPDATE.**
`.update(row).eq('id', cl.id).select('id')`, with the returned row count
checked. Same reasoning as the v4.53 lead delete: under RLS a blocked write
comes back `error: null, data: []`, so without the count check this would trade
a loud failure for a silent one. Inserts stay on the upsert path behind
`opts.insert`, passed only by `auditedUpsertClassAsync` when
`action === 'create'`. Nothing in the RLS posture moved.

**Fix B - attendance persists before it claims success.** All three
`LogAttendanceModal` `onLog` handlers (sub-cover log, class detail, today view)
now await `addAttendanceAsync` and toast after it resolves; on rejection the
modal stays open so the headcount does not have to be retyped.

`LogAttendanceModal.submit()` also stopped writing the sub-claim record itself.
It used to call `ctx.addSubAssignment` and then `props.onLog(att)` back to back
- two writes to the same class row for one button press, both built from the
same `classes` render snapshot, so the second silently clobbered the first. The
claim now rides up through `onLog` as `opts.subAssignment` and
`addAttendanceAsync` folds it into the same copy and the same UPDATE.

**Fix C - the other trainer-reachable class writes.** Sub request, cancellation
and the time-off auto-post moved to the async helpers with the toast behind the
await. `addSubAssignmentAsync` now accepts an array of assignments for one
class, and the time-off path groups conflicts by class before calling it: a
recurring class with several conflicting occurrences used to issue one call per
occurrence, each building its copy from the same stale snapshot, last write
wins. Fan-out still fires per assignment and is unchanged.

### Verification

`node --check` on the embedded JS: PASS. Diff +150/-45 against a ~+140/-55
budget; the overage is comment.

Re-run of the live probe as Victor Leak, rolled back, against the shape the new
code sends:

    v4.53-era upsert        = FAIL (row-level security)
    v4.54 UPDATE..RETURNING = OK, rows=1
    trainer INSERT          = correctly BLOCKED

The last line is the posture check: a trainer still cannot create a class. anon
still holds exactly one privilege in `public`, `trainer_directory:SELECT`. No
migration ran; this version changes no database object.

Still needs Selisa's iPad pass on production before the decision record is
logged.

### Deferred

- `addAttendance` is now unreferenced. `addSubAssignment` and `addCancellation`
  keep one caller each. Removal is its own version.
- `_saveIfDirty` sets `ref.current = null` on failure, so anything that later
  treats `classesRef.current` as the freshest list has to tolerate a null.
  Nothing in v4.54 does.
- The bulk `storage.classes.save` upsert stays reachable for admins. Every
  trainer-reachable path is off it now, but the shape is still there and will
  bite again if a new trainer-facing class mutation is wired to the sync
  helpers.

---

## v4.53 - July 30, 2026

Deleting a lead deletes it. The old handler removed the row from React state
and wrote nothing, so the next array save upserted every surviving lead, the
realtime channel echoed, the app refetched, and the deleted lead came back.

### Trigger

Reagan deleted a batch of test leads in the consult queue and watched every one
of them repopulate within seconds.

### Goal

A lead an admin deletes stays deleted, on that iPad and every other one. A
delete that does not land says so instead of reporting success.

### File version

v4.53 - 31,586 lines, 1.4 MB (`RoundRock_Fitness_Tracker.html`)

### The bug

`deleteQueueEntry` was three lines and touched only React state:

    function deleteQueueEntry(id){
      setQueue(function(list){ return list.filter(function(x){ return x.id !== id; }); });
    }

Nothing else in the chain covers for that. `makeEntity.save` is
`upsert(rows, { onConflict: 'id' })` with no DELETE branch, so a row dropped
from the array is simply not mentioned in the write. `makeEntity.load` is
`select('*')` with no filter. `leads` is one of the five tables in the
`supabase_realtime` publication, so the upsert of the survivors echoed back and
triggered the refetch that brought the row home.

Confirmed against live data before any edit. Eleven leads present, ten of them
carrying an identical `updated_at` of `2026-07-30 19:47:09.905+00` and one at
`19:46:54.631`. One timestamp to the millisecond across ten rows is a single
array upsert, not ten deletes. Same tell as the 60 classes in v4.52.

The toast made it worse rather than exposing it: `ctx.toast('Lead deleted')`
fired synchronously next to a call that returned `undefined`. Pattern B, with
the twist that there was no write to await in the first place.

### Changes

**Fix A - `deleteQueueEntry` deletes server-side and awaits before dropping the
row.** `.from('leads').delete().eq('id', id).select('id')`, and the returned row
count is what gets checked. RLS filters rather than errors, so a blocked delete
comes back `error: null, data: []`; without the count check a non-admin would
watch the row vanish locally and return on reload. Admin is now checked in the
handler, not only at the render. On success the updater advances
`queueRef.current` so the dirty-check save effect skips the redundant
full-array upsert and the realtime echo that goes with it.

**Fix B - a lead a client points at cannot be deleted.** `clients.from_queue_id`
carries no foreign key, so nothing in the database stops a delete from orphaning
that pointer. Two live leads are in that state right now, Laurie Helton and
Selisa Woessner, and neither is status `converted`, so the existing render gate
did not cover them. The guard reads in-memory clients and names the linked
client in the rejection.

**Fix C - the toast moved behind the await.** Success closes the modal, failure
leaves the lead on screen with the reason.

Hard delete rather than soft was the deliberate call. `leads` has no
`deleted_at` column, the `del_admin` RLS policy already existed for exactly
this, and a soft-delete flag would have meant a migration, two translator
entries that have to round-trip snake, two more keys on
`LEADS_ALLOWED_COLUMNS`, and a filter on every raw `queue` read site. Missing
one of those sweeps is what left 60 deleted classes rendering before v4.52. It
would also have broken the 5am importer: `open_lead_for` matches on
`OPEN_LEAD_STATUSES` and would treat a soft-deleted lead as an open one,
silently suppressing a real new lead for that person.

### Test results

- `node --check` on the embedded JS: PASS.
- Diff +73/-5 against a ~+55/-8 budget. The overage is comment, not logic.
- Live leads before the data cleanup: 11. After: 4.

### Deferred

- `makeEntity.save` early-returns when `rows.length === 0`, so emptying any
  entity list persists nothing. Same class of bug, wider surface.
- `activeQueue` filters on `q.deleted_at`, a column the leads table does not
  have. Dead filter, harmless, confusing to read.
- Multi-device resurrection: another iPad holding a stale array can re-upsert a
  deleted row on its next dirty save. Pre-existing for every entity.
- A hard-deleted lead leaves no record anywhere. If a deletions log is wanted it
  is its own version.
- The Delete button has no in-flight guard. A double tap fires two deletes and
  the second reports that it did not land.

### iPad test checklist for v4.53

- As an admin, delete a throwaway lead. It should disappear and the sync dot
  should settle. **Reload the app. If it comes back, the fix did not take.**
- Delete a lead on one iPad, reload a second iPad, confirm it is gone there too.
- Open Laurie Helton or Selisa Woessner as an admin and press Delete. It should
  refuse and name the linked client. **If it deletes, Fix B did not take.**
- Sign in as a trainer and confirm the Delete button is not rendered at all.

### The lesson

One identical millisecond timestamp across a batch of rows is the fingerprint of
a single array write, and it has now been the tell twice in two days. The 60
classes in v4.52 shared `15:43:00.322`. The ten leads here shared
`19:47:09.905`. When something looks deleted and is not, check whether every
survivor was touched at the same instant. That reads the write path without
opening the code.

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
