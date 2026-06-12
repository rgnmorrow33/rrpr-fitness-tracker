# Round Rock Fitness Tracker - Architectural Decision Records

**Purpose.** This is the ADR log for the tracker. It captures
significant architectural decisions, the context behind them, the
chosen direction, and the consequences accepted in choosing it. New
decisions land here as numbered records; superseded decisions stay
in the log with status updated so the history is auditable.

ADRs are committed alongside the change that implements them
whenever possible. When a decision precedes implementation (as with
all three foundational ADRs below), the ADR lands first and the
implementation references the ADR number in its commit messages.

## ADR format

Every ADR follows this shape:

| Field | What goes here |
|---|---|
| Number | Sequential, zero-padded to four digits (ADR-0001, ADR-0002, ...). |
| Title | Short, declarative. The decision in one phrase. |
| Status | One of: Proposed, Accepted, Deprecated, Superseded. |
| Date | YYYY-MM-DD. The date the status was last set. |
| Context | What situation forced the decision. What was tried, what failed, what's pressing. |
| Decision | The choice. Stated declaratively. |
| Consequences | What this choice commits us to. Both the good and the costs. |
| Notes | Anything else worth preserving: dependencies, ratification path, links to specs or chats. |

## Status definitions

- **Proposed.** Drafted but not ratified. May still change shape based
  on review. Code may or may not yet reflect the decision.
- **Accepted.** Ratified and in effect. Code is expected to align with
  the decision, or be on a roadmap to align with it.
- **Deprecated.** The decision was once Accepted but is no longer in
  force. Kept in the log for historical context. May or may not have
  a replacement.
- **Superseded.** Replaced by a later, numbered ADR. The superseding
  ADR is named in the Notes field.

Status transitions are themselves audited via Git commit history.
Editing a status updates the ADR's Date field and creates a commit
explaining the transition.

---

## ADR-0001: Round Rock Fitness Tracker as permanent system

**Status.** Accepted
**Date.** 2026-06-12

### Context

The tracker was originally framed as a stopgap. The implicit horizon
was "use this until Vagaro replaces Sling for fitness-side platform
operations and absorbs the tracker's workflows." Under that framing,
engineering investment was deliberately scoped down: no migration
discipline, no formal test harness, no architecture documentation, no
ADR log. The single-file React-from-CDN deployment was a fit for a
stopgap and an awkward fit for anything longer-lived.

On 2026-05-15, Reagan reframed in conversation. Vagaro is not on the
procurement roadmap. Sling will continue to handle scheduling. The
tracker is what PARD fitness operations actually run on today, and
the planning horizon should reflect that. APC opens April 2027, and
APC's fitness operations will be on this system from day one.

### Decision

The Round Rock PARD Fitness Tracker is the operating system for PT
and fitness team workflows at CMRC, Baca, and the forthcoming APC.
Multi-year horizon assumed. No replacement is on the roadmap.

### Consequences

- **Engineering rigor obligations.** Schema migration discipline,
  version-controlled SQL, a backup / restore drill, a basic test
  harness, and documentation patterns are now required. This ADR
  log, SCHEMA.md, and ARCHITECTURE.md are part of meeting that
  obligation. The full set of obligations is sequenced via ADR-0003
  Phase 2B.
- **Architectural decisions amortize over years.** Investments that
  felt over-scoped for a stopgap (normalized schema, decomposed
  single-file, RLS hardening, PIN hashing) are now defensible. The
  cost of doing them is paid back across the multi-year horizon.
- **APC integration is in scope.** Multi-facility scaling
  (CMRC + Baca + APC) is a near-term requirement, not a hypothetical.
- **Institutional review eligibility is real.** City IT review,
  internal audit, and any future compliance review can now ask for
  this system's documentation. The rigor artifacts need to be good
  enough to hand over without an embarrassing scramble.
- **Stakeholder expectations shift.** Selisa, Rick, and downstream
  consumers (front desk, trainers, division admin) should be told
  this is the system, not the placeholder. The one-pager that drives
  this ratification is the vehicle.

### Notes

Ratified by Selisa (Asst. Head of Facilities, CMRC), June 12, 2026.
ADR-0003 Phase 2B is now ungated; ADR-0002's ratification contingency
is resolved.

Council record preserved in the 2026-05-15 chat history.

---

## ADR-0002: Pairs / Group package architecture (Q1-Q4 foundational decisions)

**Status.** Accepted (pending Phase 2 execution)
**Date.** 2026-05-15

### Context

The data model has zero shared-package primitives today. Pairs in
production are two duplicate client records, each with their own
package, each receiving redundant sign-offs at every shared session.
Operational pain has surfaced: divergent session counts when one
record gets signed and the other doesn't, double-counted package
consumption, no canonical "this is a shared session" view, no way
to express N>2 group packages at all.

The 2026-05-15 Council evaluated four foundational architecture
choices to support pairs and group packages as first-class
primitives. Phase 1 diagnostic by Code (the pairs report) informed
the decisions and surfaced the trade space on each question. All
four decisions are coupled: choosing differently on any one would
push consequences onto the others.

### Decision

- **Q1 (session row count).** One shared session row per shared
  session, with N participants referenced. Not N rows per shared
  session.
- **Q2 (linkage shape).** Junction table
  `client_package_participants(client_id, package_id, joined_at,
  left_at)`. Not a denormalized array column on `clients` or on
  `packages`.
- **Q3 (sessions home).** Normalize sessions out of `clients.sessions`
  JSONB into a dedicated `sessions` table. Necessary precondition for
  Q1: shared-session-with-N-participants is not expressible inside
  the per-client `sessions` JSONB.
- **Q4 (scope).** N>=2 designed in from day one; N=2 (true pairs)
  shipped first. The schema supports group packages of arbitrary N;
  the UI ships the pairs case and extends to larger groups
  incrementally.

### Consequences

- **Multi-sprint Phase 2 effort.** This is the largest single
  architectural shift in the system's history. Sequenced via ADR-0003
  across roughly 4 to 6 months.
- **JSONB-to-normalized migration.** `clients.sessions` JSONB stops
  being the source of truth at Phase 2C completion. Existing rows
  migrate via a one-time script; new writes target the normalized
  table. The audit log of the migration itself becomes a load-bearing
  artifact.
- **Engineering foundation prerequisite.** Phase 2C is not safe to
  execute without the rigor pieces (version-controlled SQL,
  backup / restore drill, smoke test harness) in place. Phase 2B
  exists to satisfy that prerequisite.
- **Read-path rewrites.** Every code path that reads `client.sessions`
  needs to be ported. There are many. The audit cascade query inside
  `EditTrainerModal`'s preview-step `Promise.all` is one of the
  heavier ones; many sub-components read the field directly.
- **Future flexibility.** Group fitness packages, family packages,
  and corporate wellness contracts all become expressible without
  another foundational shift.

### Notes

Council record preserved in the 2026-05-15 chat history. The
ratification contingency on ADR-0001 is resolved as of 2026-06-12
(ADR-0001 Accepted); the duplicate-client-workaround fallback no
longer applies.

Will partially supersede ADR-0004 on the JSONB-on-clients rationale,
specifically the `sessions` JSONB portion. `packages` and
`audit_log` JSONB remain in place pending separate review.

**Addendum (2026-05-15): pre-existing `package_participants` orphan
table.** Schema reconciliation against the live Supabase DB surfaced
a pre-existing `package_participants` table that was not known when
this ADR was drafted. The table is empty (0 rows), has no FK
constraints, and is not referenced anywhere in the codebase. It
pre-dates this ADR's planning for the `client_package_participants`
junction table.

Phase 2C execution can either (a) rename the existing
`package_participants` to `client_package_participants` in a
migration step, or (b) drop the orphan and create
`client_package_participants` fresh under the planned name. The
choice is deferred to the Phase 2C migration spec; either option is
clean since the orphan carries no data and no soft FK relationships.

Cross-reference: SCHEMA.md "Orphan tables" section.

---

## ADR-0003: Phase 2 sequencing for pairs implementation

**Status.** Accepted
**Date.** 2026-05-15

### Context

ADR-0002 establishes the target architecture but requires engineering
foundation infrastructure that is not currently in place. Jumping
straight to the Q1-Q4 execution would mean executing the largest
schema migration in the system's history without version-controlled
SQL, without a backup / restore drill, and without a smoke test
harness to catch regressions. That's a risk profile we are not
willing to accept on a system that runs live PT operations every day.

The 2026-05-15 Council recommended a three-stage execution sequence
that lets the operational benefit start landing immediately (Phase
2A) while the foundation work proceeds in parallel-ish behind the
scenes (Phase 2B), with the destructive-but-correct architectural
shift gated on the foundation being in place (Phase 2C).

### Decision

Phase 2 runs in three atomic stages.

**Phase 2A: metadata-only pairs layer.** 1 to 2 weeks. Reversible.

- New `paired_with_client_id` field on `clients` (nullable, soft FK).
- Import-side "potential pairs detected" admin queue: heuristic
  match (same trainer, same purchase date, similar package shape)
  surfaces candidate pairs for admin review.
- Admin "designate as shared" action: stamps the field on both
  client records, keeping the duplicate-record workaround intact
  but now annotated.
- Pair-link badge on ClientDetail: surfaces the paired client.
- No data model change beyond the one field. Fully reversible by
  dropping the column.

**Phase 2B: engineering foundation.** 4 to 6 weeks. Required before
Phase 2C.

- Schema migrations as version-controlled SQL files
  (`/sql/migrations/` with timestamped names).
- Backup / restore drill: documented runbook, tested at least once.
- Smoke test harness: at minimum a smoke suite that catches the
  CLAUDE.md "green-then-red" toast / persist class of bug for the
  most-trafficked entities (clients, leads, classes, time_off).
- Single-file decomposition started: extract storage adapter,
  translators, and at least one major view as separate files served
  via Netlify. Does not need to finish in this phase, just needs to
  start with a coherent pattern others can follow.
- Invisible to Rick (and to trainers) by design. Selisa and Reagan
  feel it most via faster diagnosis and lower regression risk.

**Phase 2C: Q1-Q4 architecture execution per ADR-0002.** 8 to 12
weeks.

- New `sessions` table with the shared-session-N-participants model.
- New `client_package_participants` junction table. (See ADR-0002
  Notes addendum for the `package_participants` orphan finding that
  affects this phase.)
- Migration script porting `clients.sessions` JSONB into the
  normalized table. Audit-logged at the row level.
- All read paths ported. Old JSONB column kept temporarily for
  rollback safety, then dropped in a follow-up commit once the new
  path has soaked for a release.
- True pairs UI lands (the user-visible payoff).

### Consequences

- **Total horizon roughly 4 to 6 months.** Aligns with APC opening
  April 2027 and leaves headroom for an APC-specific
  multi-facility hardening pass before that opening.
- **Rollback at any stage is the prior stage.** Phase 2A is
  reversible by dropping the field. Phase 2B has no schema impact
  on the running system. Phase 2C keeps the old JSONB column
  during the soak period.
- **Phase 2B is invisible to Rick.** This is a chip-balance impact
  that Reagan needs to manage upward. The foundation work is real
  engineering value that doesn't show up in screenshots.
- **Sequencing risk if APC date moves.** If April 2027 slips out,
  the timeline has slack. If it slips in, Phase 2C may compress or
  defer until after APC opens.

### Notes

Phase 2A begins after Bucket 2 (the SCHEMA / DECISIONS / ARCHITECTURE
artifact set) and the Selisa one-pager land. The spec for Phase 2A
is drafted but not yet executed.

Phase 2B's "single-file decomposition started" item is the execution
edge of the posture captured in ADR-0005 (single-file deployment
posture for the prototype phase).

---

## ADR-0004: JSONB-on-parent as the operative data model for client subrecords

**Status.** Accepted (retroactive capture)
**Date.** 2026-05-18

### Context

The tracker's primary entity (`clients`) carries three substantive
data structures inside JSONB columns rather than as rows in
normalized child tables:

- `clients.sessions` - the full PT session history, including
  status, sign-off state, duration, recurring-series linkage, and
  service-recovery fields.
- `clients.packages` - the list of purchased packages with type,
  size, validity window, soft-delete state, and source provenance.
- `clients.audit_log` - the per-client append-only history of
  mutations, capped at the last 100 entries.

This shape was not the result of a documented decision at the time
the data model was built. It crystallized iteratively under
prototype-phase pressure: schema migrations were expensive to
coordinate during early iteration, the React-from-CDN single-file
deployment had no migration tooling attached, and adding a JSONB
field was free in a way that adding a table was not.

The v4.18 schema reconciliation surfaced the smoking gun: a
`packages` table exists in the live Supabase DB, is empty, has no
FK constraints, and is not referenced anywhere in the codebase
(see SCHEMA.md "Orphan tables"). Someone at some point stubbed out
a normalized packages table; the app never wired it up; the JSONB
column on `clients` became the de-facto data model. Until SCHEMA.md
v4.17, the JSONB posture was unwritten and lived only in the code.

This ADR captures the posture retroactively so that future
architectural decisions - particularly ADR-0002 Q3, which normalizes
`clients.sessions` out into a dedicated `sessions` table - have an
explicit starting point to supersede.

### Decision

For `clients.sessions`, `clients.packages`, and `clients.audit_log`,
the operative data model is JSONB columns on the `clients` row.
Writes are whole-row upserts via the standard
`from('clients').upsert(rows, { onConflict: 'id' })` path; the
JSONB column is replaced wholesale on every save. Shape is enforced
by code convention via canonical constructor functions, not by
DB-level validation.

- **`clients.sessions`** is constructed by `addSession`,
  `createRecurringSessions`, and `rescheduleSeriesFromHere`.
  Sign-off, recurring series, and service-recovery fields are
  documented in SCHEMA.md "JSONB shapes" `clients.sessions[]`.
- **`clients.packages`** is constructed by `addPackageToClient`
  and `buildSeedClients`. Per Sprint K, derived fields
  (`sessionsUsed`, `sessionsRemaining`, `is_active`) were dropped
  from the stored shape and are computed live from
  `clients.sessions[]`. Documented in SCHEMA.md "JSONB shapes"
  `clients.packages[]`.
- **`clients.audit_log`** is constructed by `appendAuditEntry`, a
  single canonical helper that builds the 13-field entry, concats
  onto the existing log, and trims to the last 100 entries.
  Documented in SCHEMA.md "JSONB shapes" `clients.audit_log[]`.

### Consequences

- **Write atomicity is cheap.** A session sign-off that also
  appends an audit entry and stamps a package state change is one
  upsert against one row, with no cross-table transaction
  coordination. The dirty-check `_saveIfDirty` useEffect on
  `setClients` handles persistence asynchronously without the
  caller having to think about multi-table consistency.
- **Schema flexibility is high.** Adding a new field to a session
  row, a package row, or an audit entry requires zero migration -
  the JSONB column accepts whatever shape the constructor builds.
  This was load-bearing during early iteration when Selisa's
  feedback was driving multiple field additions per sprint.
- **Query complexity is high.** Aggregates that span entities
  (rename cascades, audit reporting, package-expiring sweeps) have
  to fetch whole rows and walk the JSONB arrays in JavaScript.
  There is no SQL path for "all sessions for trainer X in date
  range Y" without pulling every client.
- **Type safety is none.** Shape is enforced by the constructor
  helpers and by code that reads the shape. A drift between
  constructor and reader is a runtime render bug, not a schema
  rejection. The Patch R whitelist on `leads` is the precedent for
  what a belt-and-suspenders second filter looks like when this
  matters; the JSONB columns have no equivalent today.
- **Concurrency is last-write-wins on the whole row.** Two devices
  writing to the same client at overlapping times will both upsert
  the whole row; the later write overwrites the earlier. The
  100-entry `audit_log` trim runs per device per write, so the log
  can briefly leak past 100 entries when concurrent writes land
  before the next write trims it back. Self-heals via the
  whole-row last-write-wins; the realtime subscription reload
  picks up the most recent state within ~100ms.
- **The pattern extends beyond `clients`.** Other entities apply
  the same JSONB-on-parent shape for similar reasons (see SCHEMA.md
  "JSONB shapes" and the per-entity `audit_log` columns documented
  there). Full enumeration is out of scope for this ADR; see "Out
  of scope" below.

### Out of scope

This ADR documents the posture only for the three `clients.*`
columns named in the Decision section. The following related cases
are explicitly *not* covered here:

- **`notifications.payload`.** JSONB, but holds opaque per-type
  message metadata rather than a primary data structure.
  Render-time code in `notificationText` consumes it directly.
  Not part of this posture.
- **Per-entity `audit_log` generalization.** The same append-only
  100-entry head-trim pattern is applied via `appendAuditEntry` to
  `trainers`, `leads`, `closures`, `classes`, `schedule_versions`,
  and `trainer_time_off`. The general rationale for entity-local
  audit logs (rather than a centralized audit table) is queued for
  a separate forward-looking ADR: *append-only audit log embedded
  per entity* (proposed; see Backlog).
- **Other JSONB-on-parent instances.** `classes.sub_assignments`,
  `classes.attendance`, `leads.status_history`,
  `schedule_versions.data`, and `trainers.previous_names` apply the
  same architectural posture to other parent entities. Acknowledged
  in the Consequences section above with a SCHEMA.md
  cross-reference; not enumerated individually here.

### Notes

This ADR is a retroactive capture of existing architecture, not a
new decision. Status lands as Accepted directly per the "How to
add a new ADR" guidance for backfill ADRs that document existing
patterns.

ADR-0002 Q3 normalizes `clients.sessions` out into a dedicated
`sessions` table to support shared-session-N-participants for
pairs. Phase 2C of ADR-0003 is the execution sprint for that
normalization. Once Phase 2C completes and the JSONB `sessions`
column is dropped, this ADR is partially superseded for the
`sessions` portion; `clients.packages` and `clients.audit_log`
remain JSONB pending separate review.

Cross-references:
- SCHEMA.md "JSONB shapes" section for the canonical shape of each
  column.
- SCHEMA.md "Orphan tables" section for the `packages` empty-table
  finding that prompted this ADR.
- ADR-0002 / ADR-0003 for the sessions-normalization roadmap.

---

## ADR-0005: Single-file deployment posture for the prototype phase

**Status.** Accepted (retroactive capture)
**Date.** 2026-05-18

### Context

The entire tracker ships as a single file: `RoundRock_Fitness_Tracker.html`
contains all HTML, CSS, and JavaScript (currently 25,836 lines).
React 18 loads from `unpkg.com` as a UMD bundle. Components are
written using `React.createElement` rather than JSX so no transpiler
is needed. There is no build step, no module system, no bundler
config, no `package.json`. The HTML file is the deployable.

Deployment is Netlify auto-deploy from `main`: push to repo, Netlify
rewrites `/` to `/RoundRock_Fitness_Tracker.html` per `netlify.toml`,
iPads revalidate on every load per `_headers` cache headers, change
reaches production iPads within ~30 seconds of merge.

This shape crystallized under prototype-phase constraints: Reagan as
sole contributor, Claude Code as the editing tool, Selisa as the QA
partner reading only the running app (not source), no other readers.
Adding a build pipeline would have introduced bundler config drift,
deploy coordination, and CI cycle time without unlocking any
capability the team needed at that horizon.

ADR-0001 (the 2026-05-15 reframe) committed the tracker to multi-year
status with APC opening April 2027. Engineering rigor obligations
follow. The single-file shape was the right call for the prototype
phase but is on a roadmap to change: ADR-0003 Phase 2B starts
extracting storage adapter, translators, and at least one major view
as separate files served via Netlify. This ADR captures the posture
so the decomposition has an explicit starting point and so the
criteria for when to fully unwind are documented ahead of time.

### Decision

Keep the single-file shape for the prototype phase. All app code
lives in `RoundRock_Fitness_Tracker.html`. No build step, no module
system, no test harness.

Decomposition is sequenced via ADR-0003 Phase 2B (engineering
foundation): storage adapter, translators, and at least one major
view extracted to separate files served via Netlify. Phase 2B starts
the unwind; full decomposition is a longer arc tracked under the
criteria below.

### Consequences

**Pros (why this is the right shape for now).**

- **No build pipeline.** Edit, save, commit, push - Netlify deploys
  in ~30 seconds. No bundler config to debug, no transpile errors
  at deploy time, no CI cycle to wait on. The deploy flow Reagan
  can execute end-to-end is the same flow Claude Code executes.
- **Every change is one diff.** A feature, a fix, and a refactor
  all land as a unified diff against one file. No cross-file
  coordination, no import-graph reasoning to verify a refactor
  didn't break a downstream module.
- **No bundler config drift.** Tooling that doesn't exist doesn't
  break. No `webpack.config.js` to maintain, no `vite.config.ts` to
  update, no Node version pinning, no `npm audit` triage cycles.
- **Easy grep and edit.** Every symbol in the app resolves to one
  file. Grep for a function name, find every call site, every
  definition - one file, one result set. No "where does this live"
  navigation cost.
- **Onboarding is reading one file.** Claude Code can be given the
  whole file as context. Future readers (auditors, contracted
  developers, security reviewers) get the entire app in one place
  without needing to assemble a mental model from module boundaries.

**Cons (the costs we accept by keeping this shape).**

- **Navigation slows as the file grows.** At ~26k lines, jumping
  between related functions is several screens or a search. At 35k+
  this compounds. The decomposition criteria below name the
  threshold where this cost outweighs the wins.
- **IDE perf degrades.** Syntax highlighting, autocomplete, and
  language server features slow noticeably on a single 26k-line
  file. Some editors refuse to parse past certain sizes. At 35k+
  this becomes painful.
- **No module isolation.** All functions share one scope. Helpers,
  components, storage adapters, validators all see each other.
  Renames cascade silently; a typo can shadow another symbol with
  no compile-time warning.
- **No test harness possible without restructuring.** Unit tests
  need importable modules. Per ADR-0003 Phase 2B, the smoke test
  harness is a blocker for Phase 2C; achieving it requires at least
  starting decomposition.
- **Browser DevTools and iPad Safari debugging is painful.** Stack
  traces all resolve to `RoundRock_Fitness_Tracker.html:NNNNN` with
  no module names. Setting breakpoints in a 26k-line file is slow;
  bisecting a regression via stack traces compounds the navigation
  cost above. Tolerable while Reagan + Claude Code are the only
  readers; cost compounds if that changes.
- **Line-number doc references drift.** SCHEMA.md, ARCHITECTURE.md,
  and earlier ADRs cite specific line numbers in
  `RoundRock_Fitness_Tracker.html` that go stale within days. The
  going-forward convention (CLAUDE.md "No line-number references in
  docs") and the existing-refs sweep (CLAUDE.md "Deferred cleanup
  pile" entry filed in commit `8a3e26f`) close this gap once. New
  docs use function names or section anchors only.

### Decomposition criteria

Decompose when any of these triggers fire. Triggers are
non-exclusive: any one is enough.

- **Concurrent contributors exceed 1.** Today Reagan + Claude Code
  is the effective contributor set. The moment a second human is
  writing or reviewing code in this repo, single-file becomes a
  merge-conflict generator and a coordination cost.
- **File exceeds 35,000 lines.** Current count is 25,836.
  ARCHITECTURE.md already names ~25k as the inflection where the
  shape becomes "wrong." 35k preserves ~9k of headroom (roughly
  1-2 sprints at current pace) while staying close enough to the
  inflection to act as a forcing function. At 35k, navigation and
  IDE perf costs cross from tolerable to impeding.
- **Test harness becomes a hard requirement.** ADR-0003 Phase 2B
  names the smoke test harness as a blocker for Phase 2C (the
  sessions normalization). When Phase 2C is the next sprint,
  decomposition has to be far enough along to support import-based
  testing of the persistence path. This is the gated trigger - it
  has a known date constraint via the APC April 2027 deadline.
- **Anyone other than Reagan or Claude Code needs to navigate or
  read the source regularly as part of their role.** Examples: a QA
  partner expanding into code review, a contracted developer
  onboarding, a security or compliance auditor. "Regularly" and
  "part of their role" rule out one-off reads (e.g., Selisa pulling
  the file once to look at a specific function). If a
  sustained-reader role opens, the cost of single-file becomes a
  coordination problem rather than just an inconvenience.

### Notes

This ADR is a retroactive capture of existing architecture, not a
new decision. Status lands as Accepted directly per the "How to
add a new ADR" guidance for backfill ADRs that document existing
patterns.

ADR-0003 Phase 2B starts the unwind by extracting the storage
adapter, translators, and at least one major view as separate files
served via Netlify. Phase 2B does not have to finish the
decomposition; it has to start one with a coherent pattern that
subsequent work can follow. When Phase 2B commits, this ADR is
partially superseded for the storage adapter, translator, and
extracted-view portions. Full decomposition is a longer arc -
additional views, helpers, and cross-cutting validators will land
in follow-up sprints driven by the criteria above.

Cross-references:
- ADR-0001 for the multi-year reframe that creates the rigor
  obligation.
- ADR-0003 Phase 2B for the engineering foundation work that starts
  the decomposition unwind.
- ARCHITECTURE.md section 1 and section 9 for the deployment model
  and the named refactor target.
- CLAUDE.md "Deferred cleanup pile" entry (commit `8a3e26f`) for
  the line-number drift sweep and the going-forward convention
  against new line-number references.

---

## Backlog of proposed ADRs

The following decisions are foundational to the system as it stands
today but have not yet been formally captured as ADRs. Each is
queued by topic; they get fleshed out in follow-up commits, one per
commit or in small thematic batches, and are assigned a number at
commit time (not pre-allocated). This section makes the documentation
gap visible so it can be closed deliberately rather than discovered
later.

When other docs need to cross-reference a backlog topic, use the
italicized topic name (e.g. *anon RLS prototype posture*) rather
than a placeholder number. Once the topic commits with a real
number, cross-references can be updated to point at it.

- ***Translator pattern (snake_case at DB, camelCase in-memory).***
  Why translation lives at the storage adapter boundary rather than
  at the schema layer or in components.
- ***Append-only audit log embedded per entity*** (capped at 100
  entries via head-trim). Why entity-local rather than a centralized
  audit table. Generalizes the `clients.audit_log` slice covered by
  ADR-0004 to the other entities that use `appendAuditEntry`.
- ***Permission model: trainers EXECUTE, admins set STRUCTURE.***
  The principle and its applications across the codebase.
- ***Anon RLS prototype posture.*** Acceptable during the prototype
  phase; tightening is required before APC opens (April 2027
  deadline) or before any clinical PHI flows through the system,
  whichever comes first.
- ***PIN storage as plaintext in the `settings` table.*** Acceptable
  for prototype; hashing required before APC opens.

---

## How to add a new ADR

1. **Pick the next number at commit time.** Sequential, zero-padded.
   The next committed number follows from the last committed ADR (if
   the last committed is ADR-0007, the next is ADR-0008). Don't skip
   numbers in the committed sequence. Backlog items do not carry
   pre-allocated numbers - they appear by topic and get a number
   when they commit. If two ADRs are in flight simultaneously, the
   second to commit takes the next number.
2. **Write it in this file.** Append the ADR section above the
   Backlog block. The Backlog block stays at the bottom; only
   committed (non-Backlog) ADRs live in the numbered sequence above it.
3. **Status starts as Proposed unless it's clearly Accepted.**
   Backfill ADRs that document existing patterns can land as
   Accepted directly. Forward-looking decisions that need
   ratification (council, stakeholder review) land as Proposed
   and get a follow-up commit when status changes.
4. **One commit per new ADR, or small thematic batches.** Don't
   bundle unrelated ADRs into one commit. The Git history is the
   audit trail for when each decision was recorded and by whom.
5. **Status changes are their own commits.** Editing an existing
   ADR's status (Proposed to Accepted, Accepted to Superseded,
   etc.) updates the Date field and lands as a focused commit with
   a message that explains the transition. The commit body is the
   ratification record.
6. **Supersession is explicit.** When a new ADR replaces an old
   one, name the old ADR in the new ADR's Context section and
   update the old ADR's Notes to point at the new one. Don't delete
   the old ADR.
7. **Cross-references to backlog topics use the topic name, not a
   number.** When an ADR or another doc needs to point at a topic
   that has not yet committed, use the italicized topic name (e.g.
   *anon RLS prototype posture*) rather than a placeholder number.
   Backlog numbering happens at commit time only; placeholder
   numbers in cross-references go stale the moment another topic
   commits first. Once a topic commits, sweep cross-references to
   point at the real number.
8. **Cross-reference SCHEMA.md and ARCHITECTURE.md where useful.**
   Decisions that change schema shape should point at the SCHEMA.md
   section they affect. Decisions that change cross-cutting
   architecture should be reflected in the matching ARCHITECTURE.md
   section in the same commit.

---

*Maintained by Reagan. Questions and corrections: reaganmrrw@gmail.com.*
