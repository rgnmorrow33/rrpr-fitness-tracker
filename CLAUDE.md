# Round Rock Fitness Tracker - Claude Code Project Notes

This file is read at the start of every Claude Code session.
It encodes the conventions, decisions, and gotchas for this repo.

## What this is

Single-file HTML web app deployed on iPads at Round Rock Parks
and Recreation fitness facilities (Clay Madsen Recreation Center
and Allen R. Baca Center, with APC opening April 2027). Used by
trainers, instructors, front desk, and division administration to
track PT clinic operations, group exercise, personal training,
and member engagement.

Architecture: React 18 from CDN, no build step. All HTML, CSS, JS
in one file: RoundRock_Fitness_Tracker.html. Currently storing
data in Supabase via the storage adapter at the top of the file.

## Who uses Claude Code on this repo

Reagan (primary owner). Defines specs in a separate Claude web chat,
pastes prompts here. Selisa (Assistant Head of Facilities, CMRC) is
the QA partner. She does not use Claude Code; she runs Supabase
schema changes and tests on production iPads.

## Working conventions

### Diagnostic before fix
When something is unclear, investigate and report back BEFORE editing.
Do not guess at the cause. Use grep, file reads, and code inspection
to confirm the actual bug location.

### Plan before edits on big changes
For multi-component or architectural changes, propose the plan first
(which existing pattern is being reused, where the new code fits,
which call sites need updating). Confirm before applying.

### Batch edits in one commit
Multiple related fixes ship together as one commit with a descriptive
batched message. Avoids one-deploy-per-fix and easier rollback.

### Validate before push
Always run node --check on the embedded JS before commit. Catches
syntax errors before they reach Netlify.

### Defer non-urgent cleanups
Spotted an adjacent code smell during a fix? Flag it, don't fix it
in the same commit. Cleanups go in a dedicated commit later.

### No line-number references in docs
Docs in `/docs` (SCHEMA.md, ARCHITECTURE.md, DECISIONS.md) reference
code in `RoundRock_Fitness_Tracker.html` by function name or section
anchor, never by line number. The single-file app drifts; line refs
go stale within days. Existing line refs are tracked for sweep
under "Deferred cleanup pile."

## Writing conventions in user-facing code

- No em dashes. Use space-hyphen-space ( - ), parentheses, or two
  sentences instead.
- "Team" never "staff."
- First-name-only sign-offs in any UI text.
- Casual, conversational voice.
- No corporate filler.

## Color palette

- Navy: 1B3D5C
- Teal: 2E8B8B
- Gold: C49A4A
- Cream: F4EFE6
- Slate: 5C6970
- Border: D9D2C4

Status colors: red for critical/loss, green for success/converted,
amber for warning/aged.

A forest green / sage / pine palette rebrand is queued as a
dedicated commit. Do not ship inside a feature batch.

## Storage architecture

The app uses a storage adapter (top of script, around line ~1300)
that wraps all reads/writes. Two modes: 'localStorage' and 'supabase'.
Currently in 'supabase' mode.

Supabase project: ofezaezijafglyjmisgz.supabase.co
Anon key is committed in the file (designed-public, RLS gates access).

Storage adapter exposes: storage.X.load() / storage.X.save(arr) for
each entity. Returns Promises in both modes.

Translation layer (translate.X.toSupabase / fromSupabase) handles
camelCase to snake_case conversion at the storage boundary. The
in-memory shape stays camelCase; only Supabase writes/reads use
snake_case. Field-by-field translation maps live in translate.X.

### Entity to Supabase table name mapping

- storage.clients = clients
- storage.classes = classes
- storage.wros = wros
- storage.leads = leads
- storage.contacts = member_contacts
- storage.adminItems = admin_items
- storage.referrals = referrals
- storage.closures = closures
- storage.trainers = trainers
- storage.scheduleVersions = schedule_versions

### Local-only fields

Some lead fields don't have Supabase columns and are device-local:
followUpBy, rectracMemberId, packageInfo, lostAt. These get dropped
on write to Supabase and don't survive round-trip. Acceptable trade-
off for now.

### WROs JSONB split

The wros table has flat columns (trainer_name, client_name, date,
notes, signature_data) plus a `data` jsonb column. Pre-form goals,
post-form claim state, and conversion lifecycle live in `data`.

### Saves use dirty-check refs

Each entity's save useEffect compares current state to a ref via
JSON.stringify (timestamps stripped) before saving. Prevents pointless
network writes on unchanged data.

## Real-time subscriptions

App subscribes to postgres_changes on all 10 entity tables via a
single channel ('app-changes'). On any row change, the affected
entity reloads via storage.X.load() and the corresponding setter
fires.

Sync indicator (small green/amber dot bottom-right) shows channel
state.

Self-write echoes are tolerated for now (write happens, subscription
fires back at us, dirty-check on save catches the no-op). If
pathological behavior surfaces, an originator filter can be added.

## Permission model

Core principle: trainers EXECUTE, admins set STRUCTURE.

Trainers can: log sessions, mark attendance, sign, drop class for
sub coverage, claim sub, mark single occurrence cancelled, trigger
service recovery, add new package (re-up).

Admins only: delete a client, delete a class, delete a signed
session (both signatures present), edit class structure (name, day,
time, capacity), change package type, manage trainer roster,
override claim or release.

## Session lifecycle

Attended: both trainer and client sign. Counts against package.

No-show: trainer signs, client cannot. FULL session loss. NO SHOW
badge. Triggers service recovery popup.

Late cancel (under 24 hr): FULL session loss. LATE CANCEL badge.
Three per episode = discharge consideration.

Excused: note preserved, no loss, EXCUSED badge.

Service recovery: free text required, duration auto-matches lost
session/class length, counts as ADMIN time, separate line item on
time card.

## Hours math conventions

- GX classes 50-60 min count as 1.0 hr; otherwise actual duration
- Auto-admin = 0.25 x forward-facing hours, applied automatically
- Manual admin: Program Creation, Training, Community Event, Other
- Member contacts: Quick = 2 min, Substantive = 6 min, Educational = 15 min, capped 4 hr/period
- Service recovery: capped at lost session/class duration
- PT session duration: 1 hour or 30 minutes (chosen at log time)

## Deployment pipeline

- Repo: github.com/rgnmorrow33/rrpr-fitness-tracker (PUBLIC)
- Hosting: Netlify with auto-deploy from main
- Production site: pardfitnesstracker (Selisa's iPads)
- Test site: pardfitnesstracker2 / candid-cendol-66c876
- Local repo: C:\Docs\rrpr-fitness-tracker

Workflow:
1. Reagan describes change in Claude Code
2. Claude Code edits the file
3. node --check on embedded JS
4. git add, commit with descriptive message, git push
5. Netlify auto-deploys in ~30 seconds
6. Selisa verifies on production iPad

Do NOT rename the tracker file. The netlify.toml redirect handles
serving RoundRock_Fitness_Tracker.html at the root URL.

Do NOT put the repo in a OneDrive-synced folder. Conflicts with
Git's .git folder.

## Required field validation

- Name required on new client and WRO intake
- At least ONE of email or phone required (both is fine, minimum one)
- Email must look like email@domain.something when provided
- Phone must have at least 10 digits when stripped
- Existing records grandfathered

## Deferred cleanup pile

Tracked across all sessions. Address in a dedicated cleanup commit
when convenient.

- Trainers replace-all on save: every save sends the full profile
  array. Diff-based save would only send changed rows. Add only if
  Supabase rate limits surface.
- Self-write originator filter for sub events: subscription echoes
  our own writes back. Existing dirty-check filter handles the
  no-op, but a true originator id would be cleaner.
- Channel auto-reconnect on subscription drop. If subs actually
  drop in production it's a P1 to investigate, not cleanup.
- Lead expanded perms (canEditAnyAttendance, canEditAnySession)
  are unscoped. Future work: scope to a reporting tree once we
  have one.
- Phantom 'claimed' sub_assignments: if sub_request flow ever
  leaves orphaned claimed entries, write a one-time cleanup
  query.
- Pattern B audit (Patch G2 scope). Most ctx mutators are
  fire-and-forget setX with the global _saveIfDirty useEffect
  handling async persistence: upsertClient/auditedUpsertClient,
  upsertClass/auditedUpsertClass, addSession, addAttendance,
  addCancellation, addSubAssignment, upsertContact, upsertReferral,
  upsertWRO, addClosure, etc. Their callers fire green toasts
  before the save resolves, so a translator/schema mismatch on
  any of them surfaces as Reagan's "green then red" bug pattern
  (the one Patch P just fixed for leads). G2 should sweep them
  with the requestTimeOff / createQueueEntry persist-then-toast
  shape.
- fmtRange duplicated in two places: TimeOffManagerModal local
  (line ~25661) and TimeCardView local from Sprint O Phase 2
  (line ~16889). Lift to module scope on a future cleanup pass.
- .pill-btn CSS rule (lines 701-714) is selector-scoped to
  .audit-controls; usage at AuditView 26354/26733 and any future
  site outside .audit-controls renders with browser defaults +
  inline overrides. Sprint P Tier C1 deferred the
  ConsultQueueView filter-pill normalization here. Resolution
  options: (a) unscope the .pill-btn selector - touches shared
  CSS, Section D risk, or (b) wrap all .pill-btn usages in
  .audit-controls consistently. Defer until a Phase 2-style
  sprint can opt into shared-CSS work.
- SCHEMA.md and ARCHITECTURE.md line-number drift. Both docs
  reference specific line numbers in RoundRock_Fitness_Tracker.html
  that go stale as the single-file app changes. Already drifting
  ~22-34 lines at 3 days post-commit. Two known instances surfaced
  in ADR-0004 Phase 1 diagnostic: SCHEMA.md says createRecurringSessions
  line 6629 (actual 6607); SCHEMA.md says rescheduleSeriesFromHere
  line 6695 (actual 6661). Fix: sweep both docs and convert line-number
  references to function-name or section anchors. ARCHITECTURE.md
  has more refs than SCHEMA.md, plan accordingly. Going-forward
  convention is captured under "Working conventions" so the sweep
  is one-time, not recurring.
- SCHEMA.md clients.packages[] field-shape drift. The documented
  shape lists fields that aren't actually stamped on package rows.
  Two classes of drift, both surfaced by the Phase 2A Phase 1
  diagnostic:
    * Template-only fields documented as row fields: location,
      is_pairs, is_consult, is_intro, validDays. Actual: these
      live on PT_PACKAGES_BY_FACILITY entries only; AddPackageModal
      and the bulk import don't copy them onto the row.
      getPackageMeta(p.type) is the operative read path for any
      consumer that needs them (no runtime consumer reads is_pairs
      today; the v4.19 migrate_package_participants migration is
      the first reader, and it reads from the template, not the
      row).
    * camelCase vs snake_case soft-delete fields. Docs say
      deletedAt / deletedBy / restoredAt / restoredBy in
      camelCase. Actual stamping uses deleted_at / deleted_by in
      snake_case (softDeletePackage / hardDeletePackage). restoredAt
      and restoredBy are never stamped - restorePackage just nulls
      the deleted_at / deleted_by pair.
  Fix: rewrite the SCHEMA.md clients.packages[] field list to match
  the actually-stamped shape. Move template-derived fields to a
  separate "derived from template via getPackageMeta()" note.
  Correct the soft-delete fields to snake_case and remove the
  never-stamped restoredAt / restoredBy entries. Use function-name
  anchors per the "No line-number references in docs" convention.
- Sprint P Tier C2-aligned strays surfaced during execution:
    * Two more redundant inline maxWidth: '560px' modal
      overrides at ~21459 and ~21476 (siblings to the one
      removed from LeadDetailModal in Tier A). .modal CSS
      default is already 560px.
    * Two sibling foldLinks at ~17512 and ~20919 still use
      fontSize: '12px'; Tier C bumped the ConsultQueueView
      one (~18832) to 13px to match .section-head .meta.
      Same role, identical markup, three views.
    * NewQueueEntryModal validation errors at 16239 and 16248
      (errors.phone, errors.email) still use var(--red); Tier
      B only spec'd 16229 (errors.name). The borderColor
      counterparts at 16227, 16237, 16246 are the same pattern.
    * ConsultQueueView aged-row var(--red) at 19072 (border
      ternary) and 19103 (AGED badge bg) still use --red; Tier
      B spec did not include them.
  Mechanical sweep, ~10 line edits total. Bundle in a future
  admin-polish cleanup commit.

## Deferred features

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

## Security posture

Anon RLS allowing read/write on all tables. Acceptable for prototype.
Tighten before APC opens (April 2027) or before any clinical PHI
flows through the system, whichever first.

PIN is in the settings table. Plaintext for now. Hash before APC opens.

## Out of scope

- Payment processing (RecTrac handles)
- Member self-service portal (RecTrac handles)
- Clinical PT EMR (PTEverywhere is separate, not connected to this app)
- Email/SMS infrastructure
