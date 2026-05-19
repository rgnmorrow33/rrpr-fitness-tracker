# Round Rock Fitness Tracker - Architecture

**Purpose.** Externalize the implicit architecture of the tracker so
anyone who didn't build it can read this and understand how the
pieces fit. The system has been tribal knowledge between Reagan,
Selisa, and Code Claude for long enough; this document is the
attempt to make it legible.

**Last updated.** 2026-05-18

**Cross-references.**
- SCHEMA.md is the source of truth for table shapes, column types,
  JSONB structures, and translator mappings.
- DECISIONS.md is the ADR log capturing the architectural decisions
  that produced the current shape, including which parts are on a
  roadmap to change.

---

## 1. Overview

The Round Rock PARD Fitness Tracker is a single-page React web app
deployed on iPads at Round Rock Parks and Recreation fitness
facilities. It tracks PT clinic operations, group exercise, personal
training, member engagement, and the operational workflows around
all of the above.

**Who uses it.**

- **Trainers** execute sessions, mark attendance, sign sessions,
  drop classes for sub coverage, claim subs, log service recovery,
  and add new packages when clients re-up.
- **Leads** carry trainer caseloads but also need cross-team visibility:
  reviewing other trainers' time-off requests, reassigning consults,
  pulling team-wide reports. The view-mode toggle lets them flip
  between the trainer execution surface and the lead cockpit.
- **Admins** set structure: delete clients, edit class structure,
  manage the trainer roster, set PINs, override claims, change package
  types, and access the full audit history.
- **Front desk** is a synthetic admin session with no `trainer_id`,
  used at facility check-in stations for client/queue lookups and
  PIN-gated admin work.
- **Kiosk** is an unauthenticated WRO-intake-only surface (`role:
  'kiosk_wro'`) shown on lobby tablets for member self-service.

**Where it operates.**

- Clay Madsen Recreation Center (CMRC). Primary site.
- Allen R. Baca Center (Baca). Multi-facility live since the seed
  schedule import.
- Allen Park Center (APC). Opening April 2027; will run on this
  system from day one.

**The single-file architectural choice.** The entire app ships as
`RoundRock_Fitness_Tracker.html`. React 18 loads from CDN as a UMD
bundle; there is no build step. This was the right shape for the
prototype phase because it removed every layer between "edit the
file" and "see the change on production iPads." It is becoming the
wrong shape as the codebase grows past 25k lines; ADR-0005 captures
the posture and the decomposition criteria, and Phase 2B of the
pairs implementation (per ADR-0003) starts the decomposition.

**The reframe.** ADR-0001 captures the 2026-05-15 reframe: this is
the operating system for fitness team workflows, not a placeholder
until Vagaro lands. Engineering rigor obligations follow from that.
This document is part of meeting them.

---

## 2. Deployment model

**Source.** `github.com/rgnmorrow33/rrpr-fitness-tracker`, public
repo, `main` branch.

**Hosting.** Netlify with auto-deploy from `main`. Two sites:
- `pardfitnesstracker` (production, Selisa's iPads)
- `pardfitnesstracker2` / `candid-cendol-66c876` (test)

**The redirect.** `netlify.toml` rewrites `/` to
`/RoundRock_Fitness_Tracker.html` with status 200 (rewrite, not
redirect). Users hitting the site root see the app at the bare URL
without the filename in the address bar. The file must not be
renamed without updating the redirect.

**Cache headers.** `_headers` applies
`Cache-Control: public, max-age=0, must-revalidate` to every
asset. iPads revalidate on every load, which is what makes a code
push reach all devices within ~30 seconds of the deploy finishing
rather than waiting for cache TTL to expire. This is the v4.14
configuration; before it, sleep/wake cycles could leave iPads on
stale bundles for hours.

**Backend.** Supabase project
`ofezaezijafglyjmisgz.supabase.co`. The anon key is committed in
the HTML file by design: it's gating role on the Supabase API, not
a secret. RLS is currently disabled across all tables per the
prototype posture (see *anon RLS prototype posture*, proposed).
Supabase provides
storage, realtime, and (planned) auth.

**No build step.** The HTML file is the deployable. React loads
from `https://unpkg.com/react@18` and
`https://unpkg.com/react-dom@18` as UMD globals. Components are
written using `React.createElement` (aliased to `e`) instead of
JSX so no transpiler is needed. The trade-off is verbosity; the
benefit is zero tooling.

**No OneDrive.** The repo is at `C:\Docs\rrpr-fitness-tracker`,
deliberately outside OneDrive's sync scope. OneDrive treats Git's
`.git` folder as a collection of small text files to sync, which
causes object-store corruption.

**Deployment flow.**
1. Reagan describes the change to Code Claude in this conversation
   thread (or to web Claude for spec drafting).
2. Code Claude edits `RoundRock_Fitness_Tracker.html`.
3. `node --check` on the embedded JS (extracted to a tmp file).
4. `git add` / `git commit` with a descriptive message / `git push`.
5. Netlify auto-deploys in ~30 seconds.
6. Selisa verifies on a production iPad.

---

## 3. Data model

**Pointer to SCHEMA.md.** Table-by-table column lists, JSONB shapes,
translator mappings, and soft FK relationships are all in SCHEMA.md.
This section explains the architectural choices behind those shapes.

**JSONB strategy.** The clients table embeds three JSONB columns
(`packages`, `sessions`, `audit_log`) carrying what would be three
foreign-key-related tables in a normalized design. This was the
right call for iteration speed during the prototype phase: schema
changes for new package fields, new session fields, or new audit
shapes were free (no migrations, no information_schema reloads, no
deploy coordination). The cost is that aggregate queries (rename
cascades, audit reporting, package-expiring sweeps) have to fetch
whole rows and walk the arrays in JavaScript.

ADR-0002 establishes that `clients.sessions` will normalize out to a
dedicated `sessions` table to support the shared-session-N-participants
model required for pairs. `clients.packages` and `clients.audit_log`
stay JSONB pending separate review.

**Translator pattern.** All Supabase reads and writes pass through a
translator layer at the storage adapter boundary. In-memory
representations are camelCase; database columns are snake_case. The
`makeFieldTranslator` factory generates symmetric `toSupabase` /
`fromSupabase` functions from a field-pair map. Custom translators exist for entities whose shapes
diverge from simple field-pair mapping: `trainers` (hard-coded shape
because role and is_active have defaults), `scheduleVersions` (flat
columns plus `data` JSONB), `wros` (5 promoted flat columns plus
`data` JSONB), `notifications` (no `updated_at` column).

This is the load-bearing data contract. Any code path that reaches
Supabase without going through a translator is a bug. The Patch R
whitelist on `leads` (the `LEADS_ALLOWED_COLUMNS` constant filtering
on write) is a belt-and-suspenders second filter at the wire, added
after a translator bypass leaked an unknown column through.

**Soft-delete pattern.** Most entities have `deleted_at` and
`deleted_by` columns. Soft-deleted rows are filtered at the
component layer rather than at the storage adapter, which means
admin views can opt to show deleted records (the Audit History
viewer does). `announcement_banners` is the one exception: it uses
real `DELETE` because banners are short-lived ops broadcasts where
historical preservation has no operational value.

`trainers` has both a `deleted_at` and an `is_active` field. The
former is for soft-delete (admin action). The latter is for the
upsert-by-name save pattern: deactivating a trainer flips
`is_active` to false without altering `deleted_at`, so the row
survives subsequent upserts that include the same name.

**Audit log embedded on entity rows.** Every entity that supports
audit (clients, trainers, leads, closures, classes, schedule_versions,
trainer_time_off) carries its own `audit_log` JSONB array. Entries
are appended via `appendAuditEntry` and trimmed to the last 100. No
centralized audit table exists. The trade-off: audit queries are
per-entity (you can see the full history of one client trivially,
but cross-entity actor-centric reports require fetching all rows and
walking all arrays). For the prototype phase this is the right
shape; *append-only audit log embedded per entity* (proposed)
captures the rationale, generalizing the `clients.audit_log` slice
covered by ADR-0004.

---

## 4. Authentication and authorization

**PIN-based per-user auth.** Trainers sign in with a 4-digit PIN
stored on their row in `trainers.pin`. PINs are plaintext today;
*PIN storage as plaintext* (proposed) commits to hashing before APC
opens. The `PinModal` component collects the PIN; the match check
happens client-side against the loaded trainer row.

**Role tiers.** `role_tier` on `trainers` is one of:
- `trainer`: executes sessions, signs, claims subs, logs contacts.
- `lead`: trainer-tier permissions plus cross-team edit (reassign
  consults, decide time-off requests, view team-wide reports).
- `admin`: full access including delete, structural edits, trainer
  roster management, PIN setting, audit override.

The legacy `role` column is kept in sync with `role_tier` for older
read paths (`EditTrainerModal`'s save path writes both - was named
`RenameTrainerModal` before v4.x naming cleanup). Future cleanup:
collapse `role` and `role_tier` into one column.

**Session shape.** Three variants, hydrated synchronously from
localStorage so reload doesn't kick the user back to login (the
session `useState` initializer in the main provider reads
`rrpr_session_v1` before first render):

```
Real user:   { trainer_id, trainer_name, role, role_tier, name, signed_in_at }
Front Desk:  { trainer_id: null, trainer_name: 'Front Desk', role: 'admin',
               role_tier: 'admin', name: 'Front Desk', signed_in_at }
Kiosk:       { role: 'kiosk_wro' }
```

`name` mirrors `trainer_name` for backward compat with call sites
that read `ctx.session.name`. Session lives in localStorage at key
`rrpr_session_v1`. Sign-in is per-device by design; the session
storage is the one entity that stays localStorage-only even when
`STORAGE_MODE === 'supabase'`.

**View-mode toggle.** Lead-tier users can flip between the lead
cockpit (AdminDashboard) and the trainer execution surface
(TrainerView). The toggle is persisted per device, keyed by
`trainer_id`, in localStorage under `viewMode:<trainer_id>`. Non-lead
sessions ignore the value entirely (always `'lead'` internally, never
shown). The toggle component is `ViewModeToggle`; the state
(`viewModeTuple`) and `setViewMode` setter live alongside the
session hook in the main provider; the dispatch is exposed on the
ctx as `ctx.setViewMode`.

**Front Desk admin scope gap.** The Front Desk synthetic session has
`trainer_id: null` and `role: 'admin'`. This works for permission
checks (everything `admin` works because the role matches) but
breaks notification fan-out: the producer pattern inside
`requestTimeOff` (and the parallel sub-assigned fan-out) filters
target trainers on `is_active && p.id`, and Front Desk has no id. Front Desk admins
therefore never receive notifications about events they could
otherwise act on (time-off requests, sub assignments). This is a
known gap; the workaround today is that Front Desk admins read the
relevant views directly. Followup: either give Front Desk a synthetic
`trainer_id` and add it as an `is_active: true` row in `trainers`, or
route Front Desk into a different notification queue.

**Front Desk admin PIN.** The Front Desk session is gated by a
separate PIN stored as `admin_pin` in the `settings` table. This
existed before per-user PINs landed and is kept for the "tap any
trainer to switch" admin workflow. The legacy "1111" PIN comment
sits inside `AdminDashboard`'s actor-resolution block (grep for
`legacy 1111`).

---

## 5. Audit and observability

**`auditedUpsertClient` pattern.** Writes that need to be audited go
through `auditedUpsertClient`. The function fetches the prior record
for diffing, stamps an audit entry via `appendAuditEntry`, and routes
through the standard `upsertClient` setter so subscriptions and
saves work without special-casing. Other
entities have their own audited variants (e.g. `auditedUpsertClass`,
`addCancellation`, `addAttendance` all stamp entries).

**Action vocabulary.** The audit log uses a canonical action name per
mutation type. The current set, observed in code:

| Entity | Actions |
|---|---|
| client | `session_create`, `session_signoff`, `session_delete`, `package_added`, `package_edited`, `package_deleted`, `package_restored`, `package_hard_deleted`, `recurring_create`, `recurring_reschedule`, `recurring_cancel_all`, `consult_claim`, `soft_delete`, `restore`, `recovery_logged`, `dedup_cleanup`, `migrate_package_type_prefix`, `strip_writeonly_pkg_fields`, `migrate_package_participants` (Phase 2A lazy migration), `pair_participant_confirmed` (v4.20), `pair_candidate_dismissed` (v4.20) |
| closure | `closure_added`, `closure_deleted` |
| time_off | `timeoff_requested`, `timeoff_deleted`, `update` (decision) |
| lead | `lead_status_change`, `lead_reassigned` |
| trainer | `update`, `soft_delete`, `restore` |
| class | `attendance_logged`, `attendance_deleted` |

The Audit History viewer `AuditView` is the read side. It walks the
per-entity `audit_log` arrays, sorts by `ts`, and renders with
action-specific phrasing.

**Audit entry shape.** Documented in SCHEMA.md JSONB section. Notable
fields: `actor` (string, falls back to "unknown" when session is
missing); `actor_id` (uuid, null for Front Desk); `changes` (object,
populated only for `update` and `package_edited` actions, computed
via `diffRecords`); `amount` (number, session
consumption delta for session_* and recurring_* actions, so the audit
view can render "deducted 0.5" / "returned 1.0").

**Persist-then-toast vs dirty-check distinction.** The default save
pattern is dirty-check: mutators call `setX(newState)`, the
`_saveIfDirty` useEffect detects the change, and the save fires
asynchronously. Toasts on these surfaces fire immediately on the
local state change, which can result in the "green then red"
failure mode if the save rejects after the toast lands.

For high-stakes flows we carve out **persist-then-toast**: the
caller awaits a direct Supabase upsert before advancing local
state. The four direct-persist surfaces today are:

- `persistTimeOffRow` for time-off request/decide flows
- `persistBannerRow` and `persistBannerDelete` for announcement
  banners
- `persistQueueEntryRow` for lead creates
- `persistClientRow` for bulk client import (so per-row errors halt
  the loop)

These bypass the dirty-check save useEffect by advancing the dirty-
check ref to the post-write state, suppressing the redundant follow-
up write. Pattern B audit (in CLAUDE.md deferred pile) is the
follow-up sweep to find other surfaces that should be converted.

**Update log (external).** Version-by-version release notes live in
`Fitness_Tracker_Update_Log.docx`, owned by Reagan, outside the repo.
This is current tribal knowledge; migration into `/docs` as a
committed artifact is queued (see section 9).

**ADR log.** Architectural decisions land in `DECISIONS.md`. Five
foundational ADRs (ADR-0001 through ADR-0005) exist as of this
writing; five Tier 1 backfill topics are queued in the DECISIONS.md
backlog by topic name (numbers assigned at commit time, not
pre-allocated).

---

## 6. Realtime model

**Supabase realtime via `postgres_changes`.** Twelve entity tables
publish to a single shared channel named `app-changes`. The
subscription map is built inside the `buildAppChanges` closure of
the main realtime `useEffect`. Each entity registers a
`(table, setter, entity)` triple; the channel listener for
`event: '*'` calls a per-entity debounced reload that fetches fresh
data and dispatches the setter.

**`storage.X.load()` chain pattern.** Realtime events trigger a full
entity reload rather than incremental patches. The handler is
`reload = debounce(() => storage[entity].load().then(setter), 100)`.
This is simpler than reconciling individual row events and tolerates
out-of-order delivery; the cost is one full-table fetch per change
event on the affected entity (debounced at 100ms so bursts coalesce
into a single reload).

**Self-write echo tolerance.** When this client writes a row, the
subscription fires the same row back at us. The reload runs, fetches
the same data we just wrote, calls the setter with effectively the
same value. The dirty-check on the save useEffect catches the no-op
(JSON.stringify compare, timestamps stripped) and skips the
redundant write. This is acceptable today; an originator-id filter
to suppress self-write echo at the channel level is in the deferred
pile.

**Reconnect handling.** All channels go through `subscribeWithReconnect`
(Patch C), which exposes a builder function. The builder is invoked
on every reconnect so all `postgres_changes` listeners get re-attached
to the fresh channel.

**Wake / online / pageshow sweeps.** iPads sleep, roam wifi, and
suspend tabs. Any of these can leave channels stuck in a
non-`SUBSCRIBED` state without a hard error. The mitigation is a
sweep on three signals (the `visibilitychange` / `online` /
`pageshow` listeners attached alongside `subscribeWithReconnect` in
the main realtime `useEffect`):

- `visibilitychange` with `document.visibilityState === 'visible'`
- `window.online` event
- `window.pageshow` (Patch K, backup for iOS Safari BFCache
  restoration where `visibilitychange` doesn't fire reliably)

The sweep is idempotent: channels already in `SUBSCRIBED` are
no-ops; stale channels rebuild.

**May 15 transient disconnect learning.** A wave of transient
disconnects on 2026-05-15 surfaced a gap in `CHANNEL_ERROR` /
`TIMED_OUT` / `CLOSED` handling. The fix was to set `syncStatus` to
`'disconnected'` on any of those statuses so the bottom-right sync
dot accurately reflects state. Prior behavior left the dot green
during transient outages, which silently masked subscription drops.

**Notifications channel.** Distinct from `app-changes`. Each signed-in
trainer subscribes to a per-trainer-id channel named
`notifications-<trainerId>` (built in `buildNotifications` inside
the notifications storage adapter). Server-side filter:
`target_trainer_id=eq.<trainerId>`. Only inserts are subscribed
(`event: 'INSERT'`); read-state changes are patched optimistically
client-side. This isolation means a noisy trainer's notification
volume doesn't fan out to other signed-in devices.

**Sync indicator.** Small dot in the bottom-right corner. Green =
`SUBSCRIBED`, amber/red = anything else. The indicator is the user-
visible side effect of the `onStatus` callback on `subscribeWithReconnect`.

---

## 7. Notifications

**Producer pattern: emit at the event site.** When code performs an
action that should generate a notification, it calls
`storage.notifications.emit(targetTrainerId, type, payload)` or
`storage.notifications.emitMany(rows)` inline, right after the action
completes. There is no centralized event bus; the producer is
co-located with the mutation. This means the producer knows the
full context (actor, before/after, related entities) without having
to reconstruct it from event payloads.

**`_selfSuppress(trainerIdByName(name))` guard.** Every emit site
filters out the current actor so users don't receive notifications
about their own actions. The helper `_selfSuppress`:

```
function _selfSuppress(targetId){
  return !targetId || (session && targetId === session.trainer_id);
}
```

The `!targetId` case suppresses emits when the lookup fails (unknown
name), which is safer than firing a notification with a null target.
The `session.trainer_id === targetId` case is the self-suppression
proper. The two-condition combination is the canonical guard at
every emit site (5 trigger hooks share this pattern).

**`trainerIdByName` lookup.** Notifications target trainers by uuid,
but most call sites have a name string (because that's what's stored
on the client/lead/class record). The helper `trainerIdByName` walks
`trainerProfiles` to find a matching uuid via `trainerNameMatches`
(case-insensitive trim compare). Returns null on miss, which the
`_selfSuppress` guard then handles.

**`emitMany` for fan-out.** Multi-target events (e.g.
`time_off_requested` fans out to every active lead and admin) use
`emitMany` with a pre-built `rows` array. The filtering happens at
the producer: walk `trainerProfiles`, filter to the right tier,
exclude the requester, build the rows array, call `emitMany` once.
This is inside `requestTimeOff` for the time-off request flow.

**Notification types in use.** `consult_assigned`,
`consult_unassigned`, `time_off_requested`, `sub_admin_assigned`,
`package_expiring`. Each type has a payload convention (e.g.
`consult_assigned` carries `{clientName, clientId, date, time,
assignerName}`).

**`notificationText` centralized rendering.** Every type's
human-readable string lives in `notificationText`. The function
branches on `n.type` and returns the rendered string. The bell UI
consumer (`NotificationsBell`) calls it once per notification.
Centralizing rendering here keeps the producer side simple (just
pack the payload) and means new types only need two new pieces of
code: the producer call and the `notificationText` branch.

**`package_expiring` sweep with `existsForTrainer` dedup.** Unlike
the other notification types, `package_expiring` isn't event-driven;
it's a one-shot sweep that runs once per session, gated by
`trainer_id`. The sweep (in the `package_expiring` block of the
`NotificationsBell` useEffect) finds packages within the expiration
window, builds candidate notifications, and filters out ones that
have already been emitted for this trainer/type combo via
`existsForTrainer(trainerId, 'package_expiring', dedupKey)`. The
dedup check uses an in-memory cache built once per session
(`storage.notifications.existsForTrainer`'s IIFE). `dedup_key` in
the payload is the convention any other sweep-style trigger should
follow.

**Bell UI consumer.** Top-right bell shows unread count; tapping
opens the notification list with `notificationText`-rendered entries.
Read state patches through `markNotificationRead` with optimistic
local update and toast-on-failure rollback.

**Tier-specific notification behaviors.** Things like filter chips, a
dedicated full-list view, time bucketing, and grouping rollups are
followups outside the current scope and tracked in the deferred pile
(see section 9). The current bell UI is the same for all tiers.

---

## 8. Integrations

**RecTrac as billing source of truth.** RecTrac is the City of Round
Rock's parks & rec ERP. It owns payments, member records, package
purchases, and registration. The tracker reads RecTrac data (via CSV
exports) and never writes back. This is a deliberate boundary: if a
client's package count, payment status, or membership end date
disagrees with RecTrac, RecTrac wins. The tracker's package shape
mirrors RecTrac's, and pricing in the seed taxonomy
(`PT_PACKAGES_BY_FACILITY`) is sourced from RecTrac.

The Patch T 17-entry standardized package taxonomy
(`PT_PACKAGES_BY_FACILITY`, with its preamble comment) locked the
canonical type strings to match RecTrac's registration items. CMRC solo PT is `CMRC-PT-N`, Baca solo PT is `Baca-PT-N`, the
Baca intro pack is `Baca-1stTime-3`. Pairs are 4/8 only (no Pairs-12
or Group-* tiers). Each entry carries metadata flags
(`is_pairs`, `is_consult`, `is_intro`) that downstream code keys off
of.

**RecTrac member ID as primary match key.** `clients.rectrac_member_id`
is the highest-confidence match on import. The matcher
(`findMatchingClient`) tries member ID first, then email, then
name+DOB, then name alone.
A member ID match returns `confidence: 'high'`; a name-only match
returns `confidence: 'medium', reason: 'name match (verify)'` to
flag for admin review.

**CSV import flow.** RecTrac registration exports are pasted or
uploaded into `ImportClientsModal` (paired with its peer
`BulkImportClientsModal` for the non-RecTrac bulk path; see the
"Distinct from ImportClientsModal" comment in code for the split).
Per-row classification:
- `invalid`: missing required fields or malformed data
- `duplicate`: this row was already in this batch
- `reup`: matches an existing client; renew that client's package
- `new_to_queue`: new client, routes to the consult queue with no
  trainer assigned
- `new_to_client`: new client, fully provisioned

The classifier's `source` field on the resulting package tracks
provenance: `rectrac_import` for first-time, `rectrac_reup` for
renewals. Trainers see these in the package list with their RecTrac
origin labeled.

**Power Automate pipeline (external, no in-app code path).** The
intake pipeline that feeds the consult queue runs in Microsoft Power
Automate, outside this app. Two-pass design:

- **Pass 1 (complete).** Incoming consultation request emails get
  parsed and dropped into a SharePoint list. This is the current
  intake source for `leads`. Selisa and the consult coordinator pull
  from SharePoint and add rows to the tracker's lead queue manually.
- **Pass 2 (pending IT approval).** Direct HTTP POST from Power
  Automate into a Supabase ingestion endpoint, eliminating the
  SharePoint hop. Approval is pending from City IT for the egress
  destination.

The tracker has no in-app code path for either pass today. Documenting
the pipeline here for context; the integration boundary stops at the
SharePoint list (Pass 1) or the Supabase endpoint (Pass 2 future).

**Vagaro NOT in scope.** Per ADR-0001, Vagaro is not on the procurement
roadmap and the tracker is the operating system for fitness workflows.
Any future integration discussion lands as a separate ADR.

**Sling continues for scheduling.** Sling handles trainer/staff
scheduling and is unchanged by the tracker's existence. No
integration: the two systems are operationally adjacent but data-
independent.

**Out of scope.** Payment processing (RecTrac), member self-service
portal (RecTrac), clinical PT EMR (PTEverywhere, separate and not
connected to this app), email/SMS infrastructure.

---

## 9. Known refactor targets

This is the list of things we know need to change but haven't
prioritized into a sprint yet. Surfaces them deliberately so they
don't get rediscovered in a crisis.

**Major architectural.**

- **JSONB sessions to normalized table.** Per ADR-0002, sequenced
  via ADR-0003 Phase 2C. The largest single architectural shift
  queued. ~8 to 12 weeks of work, gated on Phase 2B foundation
  completing.
- **Single-file decomposition.** Posture and decomposition criteria
  captured in ADR-0005; execution sequenced via ADR-0003 Phase 2B.
  Extract storage adapter, translators, and at least one major view
  into separate files served via Netlify. ~4 to 6 weeks. Doesn't
  need to finish in Phase 2B, but needs to start with a coherent
  pattern.
- **Schema migration discipline.** Version-controlled SQL in
  `/sql/migrations/` with timestamped names. Today the only file in
  `/sql` is `wipe_pre_alpha_clients.sql`, a one-time data wipe.
  Phase 2B blocker.
- **Backup / restore drill.** Documented runbook, tested at least
  once. Phase 2B blocker.
- **Smoke test harness.** At minimum a suite that catches the green-
  then-red toast/persist class of bug for the most-trafficked
  entities. Phase 2B blocker.

**Operational documentation gap.** Operational documentation currently
lives in Reagan's project context (the Update Log .docx file and the
Sprint Status doc). Migration of these into `/docs` as committed
artifacts is queued. Until that happens, the canonical version-by-
version history and the live sprint backlog are not visible to anyone
who doesn't have direct access to Reagan's files.

**Security hardening (deadline-bound).**

- **Anon RLS posture.** Per *anon RLS prototype posture* (proposed).
  Tighten before APC opens (April 2027) or before any clinical PHI
  flows through the system, whichever comes first.
- **PIN hashing.** Per *PIN storage as plaintext* (proposed).
  Plaintext today. Hash before APC.

**Deferred cleanup pile (from CLAUDE.md).**

- **Trainers replace-all on save.** Every save sends the full profile
  array. Diff-based save would only send changed rows. Add only if
  Supabase rate limits surface.
- **Self-write originator filter for sub events.** Subscription
  echoes our own writes back. Existing dirty-check filter handles
  the no-op; a true originator id would be cleaner.
- **Channel auto-reconnect on subscription drop.** If subs actually
  drop in production it's a P1 to investigate, not cleanup.
- **Lead expanded perms** (`canEditAnyAttendance`,
  `canEditAnySession`) are unscoped. Future work: scope to a
  reporting tree once we have one.
- **Phantom `claimed` sub_assignments.** If sub_request flow ever
  leaves orphaned claimed entries, write a one-time cleanup query.
- **Pattern B audit (Patch G2 scope).** Most ctx mutators are fire-
  and-forget setX with the global `_saveIfDirty` useEffect handling
  async persistence. Their callers fire green toasts before the save
  resolves, so a translator/schema mismatch on any of them surfaces
  as Reagan's "green then red" bug pattern. G2 should sweep them with
  the `requestTimeOff` / `createQueueEntry` persist-then-toast shape.
- **`fmtRange` duplicated in two places.** TimeOffManagerModal local
  and TimeCardView local. Lift to module scope on a future cleanup
  pass.
- **`.pill-btn` CSS rule scoped to `.audit-controls`** when used
  outside that context renders with browser defaults plus inline
  overrides. Resolution options: unscope or wrap all usages
  consistently. Deferred pending a shared-CSS sprint.
- **Sprint P Tier C2-aligned strays.** Redundant inline modal
  maxWidth overrides, foldLinks fontSize inconsistencies,
  NewQueueEntryModal validation borderColor `var(--red)` usages,
  ConsultQueueView aged-row `var(--red)` instances. Mechanical
  sweep, ~10 line edits total. Bundle in a future admin-polish
  cleanup commit.

**Notification UX followups.**

- Tier-specific notification behaviors (filter chips, dedicated full-
  list view, time bucketing, grouping rollups).
- Front Desk admin notification scope: either give Front Desk a
  synthetic trainer_id row in `trainers`, or route Front Desk into
  a separate notification queue. See section 4 for the gap.

**Subscription performance.**

- Per-entity debounce is set at 100ms. Tuning may be needed if
  multi-trainer activity bursts surface stale-state windows.

---

## 10. Engineering practice

**`node --check` on extracted embedded JS before every push.** The
HTML file embeds ~25k lines of JS. The CI signal we don't have
otherwise comes from extracting the script block to a temp file and
running `node --check` on it. Catches syntax errors that would
otherwise reach Netlify and break production.

**Atomic commits.** One logical change per commit. If a fix touches
five files, that's one commit; if a sprint touches twenty changes,
that's twenty commits. The git log is the operational history of the
system. Commit messages are descriptive: the subject line summarizes
the change, the body explains the why and any non-obvious context.

**Diagnostic-first specs.** Reagan's standard spec shape (in CLAUDE.md):
when something is unclear, investigate and report back BEFORE
editing. Use grep, file reads, and code inspection to confirm the
actual bug location. Do not guess at the cause. Spec the change,
confirm the plan, then apply.

**iPad test checklists per version.** Selisa is the QA partner. Each
shipped version gets a per-iPad smoke test: sign in as a real trainer,
log a session, sign, verify the audit entry, check the bell. Failures
that only reproduce on iPad get a specific reproduction note for the
next debugging session.

**Update log entry per shipped change.** The version history in
`Fitness_Tracker_Update_Log.docx` gets an entry per shipped batch.
External to git; migration into `/docs` is queued (section 9). Until
then, the git log is the authoritative version history and the docx
is the trainer-facing release notes.

**ADR for architectural decisions.** When a choice is large enough
that future code will live with its consequences, write an ADR in
DECISIONS.md. New patterns, schema shape changes, security posture
shifts, sequencing commitments all qualify. Small refactors don't.

**Two-Claude workflow.** Reagan runs two Claude sessions in parallel
for nontrivial work:
- **Web Claude.** Drafts specs against the planning context (project
  history, recent decisions, open questions). Output is a spec like
  the ones that produced this document and its siblings.
- **Code Claude.** Lives on the laptop with repo access. Receives
  the spec, runs the diagnostic phase, reports findings, executes on
  greenlight. Output is code, file edits, commits.

The handoff is the spec. Web Claude doesn't touch the codebase
directly; Code Claude doesn't draft strategy. This separation keeps
both sessions focused and makes the spec itself an artifact (it's
what gets pasted into Code Claude as the canonical task description).

---

*Maintained by Reagan. Questions and corrections: reaganmrrw@gmail.com.*
