# Round Rock Fitness Tracker - Database Schema

**Purpose.** This document is the human-readable record of the
Supabase schema backing the tracker. It is hand-curated from codebase
analysis (translator maps, direct `.from()` calls, audit cascade
queries) and is the second source of truth alongside the live
information_schema view in Supabase.

**Status.** Codebase-derived v1. A future regeneration script that
pulls directly from information_schema is a deferred Bucket 3
followup. Until that lands, treat any divergence between this doc
and the live DB as a doc bug, fix it here, and note it in the
commit message.

**Last updated.** 2026-05-15

**Cross-references.**
- ARCHITECTURE.md explains the why behind these shapes (JSONB
  strategy, soft-delete pattern, audit log embedding, translator
  layer).
- DECISIONS.md captures the architectural decisions that drove
  the current shape, including the ADR-0002 / ADR-0003 sequencing
  that will eventually normalize sessions out of clients.

---

## Table inventory

The codebase touches **14 tables** across the `public` schema. The
sprint status doc (external, not in repo) references **17 public
tables**. The three-table gap is not reconcilable from code alone -
candidates are tables that exist in Supabase but aren't wired to
client code (legacy / orphan / pending feature), views counted in
the "public" total, or tables touched only by server-side triggers.
Reconciliation is deferred to a future regeneration script against
`information_schema.tables`.

| Table | Purpose | RLS | Realtime |
|---|---|---|---|
| `clients` | Core PT client records. JSONB-heavy: packages, sessions, audit_log all embedded. | Disabled | Yes (app-changes) |
| `classes` | Group exercise class definitions and per-occurrence attendance / sub assignments. | Disabled | Yes (app-changes) |
| `wros` | Wellness Recovery Outcomes intake forms. 5 flat columns plus `data` JSONB. | Disabled | Yes (app-changes) |
| `leads` | Consult queue / leads pipeline. Whitelist-filtered on write per Patch R. | Disabled | Yes (app-changes) |
| `member_contacts` | Quick / Substantive / Educational contact log per trainer. | Disabled | Yes (app-changes) |
| `admin_items` | Admin time entries (Program Creation, Training, Community Event, Other, custom). | Disabled | Yes (app-changes) |
| `referrals` | PT referrals between trainers and clients. | Disabled | Yes (app-changes) |
| `closures` | Facility closure dates (holidays, maintenance). | Disabled | Yes (app-changes) |
| `trainers` | Trainer roster with role, role_tier, PIN, soft-delete. | Disabled | Yes (app-changes) |
| `schedule_versions` | GX schedule history. Flat columns plus `data` JSONB holding the class list. | Disabled | Yes (app-changes) |
| `trainer_time_off` | Per-trainer absence requests with approval workflow. | Disabled | Yes (app-changes) |
| `announcement_banners` | Short-lived ops broadcasts to the trainer surface. | Disabled | Yes (app-changes) |
| `notifications` | Trainer-targeted server-authored messages. Per-trainer subscription. | Disabled | Yes (per-trainer channel) |
| `settings` | Key-value store. Currently holds `admin_pin` row. | Disabled | No |

RLS state per CLAUDE.md ("Anon RLS allowing read/write on all tables.
Acceptable for prototype. Tighten before APC opens (April 2027) or
before any clinical PHI flows through the system, whichever first.")
The codebase contains zero RLS-aware paths.

The 12-table `app-changes` realtime channel is set up at
`RoundRock_Fitness_Tracker.html` line 5913. The per-trainer
`notifications-<trainerId>` channel is at line 2856.

---

## Per-table detail

### `clients`

Core PT client record. The most JSONB-heavy table in the schema and
the primary target of ADR-0002 / ADR-0003 normalization work.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. Generated app-side via `freshUuid()` on insert. |
| `name` | text | Required at write-time per CLAUDE.md validation rules. |
| `email` | text | Required if phone absent. Format-validated. |
| `phone` | text | Required if email absent. 10+ digits when stripped. |
| `location` | text | "CMRC" or "Baca". |
| `date_purchased` | date | Date of first purchase (legacy seed shape). |
| `payment_type` | text | "Card" / etc. |
| `team_member` | text | RecTrac member status field. |
| `membership_verified` | boolean | Whether membership was checked at intake. |
| `membership_type` | text | "Member" / "Non-Member" / etc. |
| `membership_end` | text or date | Membership expiration date. |
| `trainer_name` | text | Assigned PT trainer (denormalized; cascade-updated on rename). |
| `referral_source` | text | How they found us. |
| `par_q` | jsonb | Health screening answers. Passthrough (no field map). |
| `from_queue_id` | text | Lead ID this client converted from (soft FK to `leads.id`). |
| `last_package_added_at` | timestamptz | Stamped by `addPackageToClient`. |
| `packages` | jsonb | Array of package records. See "JSONB shapes" below. |
| `sessions` | jsonb | Array of session records. See "JSONB shapes" below. |
| `audit_log` | jsonb | Append-only audit array, capped at 100 entries. |
| `rectrac_member_id` | text | RecTrac primary key. Used as highest-confidence match key on import. |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | DB-controlled (translator drops `createdAt` on write). |
| `updated_at` | timestamptz | Stamped on every write. |
| `deleted_at` | timestamptz | Soft-delete timestamp. |
| `deleted_by` | text | Soft-delete actor. |

**Translator mapping** (`RoundRock_Fitness_Tracker.html:2327-2344`):
camelCase in-memory → snake_case at DB for the 13 pairs in the
makeFieldTranslator map. Unmapped keys pass through unchanged.

**Soft FK references** (no DB constraint, enforced by code):
- `from_queue_id` → `leads.id`
- `trainer_name` → `trainers.name` (rename cascade in
  `RenameTrainerModal`, line 22960+, rewrites this column on rename)

### `classes`

Group exercise definitions. Each row carries occurrence-level
attendance and sub coverage state inside JSONB columns.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `name` | text | Class name (e.g. "CM HIIT", "Aqua Fit"). |
| `location` | text | "CMRC" or "Baca". |
| `instructor` | text | Primary instructor (cascade-updated on rename). |
| `day_of_week` | text | Full name ("Monday", etc). Legacy 2-letter codes normalized at read. |
| `start_time` | text | "HH:MM" 24h. |
| `end_time` | text | "HH:MM" 24h. |
| `duration_minutes` | integer | Auto-derived in places, explicit in others. |
| `room` | text | Where it meets. |
| `capacity` | integer | Soft-warn only today (no hard block). |
| `class_type` | text | "Strength & Conditioning", "Cycle", etc. |
| `is_premium` | boolean | Premium class flag. |
| `sub_assignments` | jsonb | Array. See "JSONB shapes" below. |
| `attendance` | jsonb | Array. Per-occurrence attendance records. |
| `season_start` | date | Schedule window start. |
| `season_end` | date | Schedule window end. |
| `schedule_version_id` | uuid | Soft FK to `schedule_versions.id`. |
| `audit_log` | jsonb | Append-only. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `deleted_at` | timestamptz | Soft-delete. |
| `deleted_by` | text | Soft-delete actor. |

**Translator mapping** (line 2346-2361).

### `wros`

WRO intake form. JSONB-split pattern: the 5 most-queried fields
are promoted to flat columns, everything else lives in `data`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `trainer_name` | text | Promoted from `data.post.specialistName`. |
| `client_name` | text | Promoted from in-memory `participantName`. |
| `date` | date | Intake date. |
| `notes` | text | Promoted from `data.post.postNotes`. |
| `signature_data` | text | Base64 signature payload. |
| `data` | jsonb | Everything else (pre-form goals, post-form claim state, conversion lifecycle). |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2517-2561, custom). The flat columns are
the ones the audit / time-card queries filter or count by; the rest
stays in JSONB so the WRO form can evolve without migrations.

### `leads`

Consult queue / leads pipeline. Confirmed column set via the May 11
information_schema query (preserved in code as `LEADS_ALLOWED_COLUMNS`
at line 2621-2628). Writes are whitelist-filtered before upsert per
Patch R - any key not in the allowed list is dropped at the wire.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `name` | text | Lead name. |
| `email` | text | Required if phone absent. |
| `phone` | text | Required if email absent. |
| `source` | text | Where the lead came from. |
| `interest_area` | text | What they want help with. |
| `status` | text | "waiting" / "assigned" / "converted" / "lost". |
| `status_history` | jsonb | Array. See "JSONB shapes" below. |
| `assigned_to` | text | Trainer name (cascade-updated on rename). |
| `notes` | text | Free text. |
| `consult_date` | date | Scheduled consultation date. |
| `converted_at` | timestamptz | When status flipped to converted. |
| `converted_to_client_id` | uuid | Soft FK to `clients.id`. |
| `source_tag` | text | Marketing channel tag. |
| `added_by` | text | Sign-in name of creator. |
| `assigned_at` | timestamptz | When status flipped to assigned. |
| `assigned_by` | text | "admin" or claimer's name. |
| `lost_reason` | text | Why the lead was marked lost. |
| `from_wro_id` | uuid | Soft FK to `wros.id` (WRO-originated leads). |
| `audit_log` | jsonb | Append-only. |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2400-2424).

**Local-only fields** (in-memory only, dropped at the translator):
- `followUpBy`, `rectracMemberId`, `packageInfo`, `lostAt`, `date`

These survive in localStorage mode but get filtered before any
Supabase write. Acceptable round-trip loss for now.

### `member_contacts`

Quick / Substantive / Educational contact log per trainer. CLAUDE.md
hours math: Quick = 2 min, Substantive = 6 min, Educational = 15 min,
capped at 4 hr per period.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `trainer_name` | text | Logger (cascade-updated on rename). |
| `member_name` | text | Member contacted. |
| `type` | text | "quick" / "substantive" / "educational". |
| `notes` | text | Free text. |
| `logged_at` | timestamptz | When the contact happened. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2363-2366).

### `admin_items`

Admin time entries. Includes manual admin categories (Program
Creation, Training, Community Event, Other), service recovery rows,
and custom categories.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `type` | text | One of the canonical categories or "custom". |
| `custom_type` | text | Free-text label when `type === 'custom'`. |
| `time_in` | timestamptz | Start. |
| `time_out` | timestamptz | End. |
| `assignees` | text[] | Trainer names. NOT JSONB - flat text[]. |
| `notes` | text | Free text. |
| `source_session_id` | uuid | Set on service recovery rows; points to the session that triggered the recovery. |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2368-2375).

### `referrals`

PT referrals between trainers.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `client_id` | uuid | Soft FK to `clients.id`. |
| `client_name` | text | Denormalized client name at referral time. |
| `referred_by` | text | Source trainer (cascade-updated on rename). |
| `notes` | text | Free text. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2377-2382).

### `closures`

Facility closure dates.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `date` | date | Closure date. |
| `reason` | text | Free text. |
| `facility` | text | "CMRC", "Baca", or "all". |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `audit_log` | jsonb | Append-only. |

**Translator mapping** (line 2384-2388).

### `trainers`

Trainer roster. The only entity that uses upsert-by-name on save
(instead of upsert-by-id) and soft-deletes by toggling `is_active`
to false (no DELETE).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. DB-generated for new rows added via the admin UI. |
| `name` | text | Unique. The on-conflict target for upserts. |
| `role` | text | Legacy column kept in sync with `role_tier` for older read paths. |
| `role_tier` | text | "trainer" / "lead" / "admin". |
| `pin` | text | Plaintext for now, hash before APC per CLAUDE.md. |
| `is_active` | boolean | Soft-delete via `false`. Filtered on load. |
| `previous_names` | jsonb | Rename history: `[{name, renamed_at}, ...]`. |
| `audit_log` | jsonb | Append-only. |
| `deleted_at` | timestamptz | Hard soft-delete (distinct from `is_active`). |
| `deleted_by` | text | Soft-delete actor. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator** (line 2431-2463, custom): not field-pair-based; the
toSupabase/fromSupabase functions hard-code the shape.

**Unique constraint**: `trainers_name_unique` on `name`. Required for
the upsert-by-name save pattern (line 2774).

### `schedule_versions`

GX schedule history. Flat columns for filtering / soft-delete, plus
a `data` JSONB carrying the class list snapshot for that version.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `label` | text | Display name. In-memory field is `name`. |
| `effective_date` | date | When the version goes live. In-memory `startDate`. |
| `is_active` | boolean | Derived from `activatedAt`. |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `deleted_at` | timestamptz | |
| `deleted_by` | text | |
| `data` | jsonb | `{endDate, activatedAt, classes[]}`. |

**Translator** (line 2477-2510, custom).

### `trainer_time_off`

Per-trainer absence requests with approval workflow.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `trainer_id` | uuid | Soft FK to `trainers.id`. |
| `kind` | text | "sick" / "vacation" / "personal" / etc. Passthrough (no field map). |
| `status` | text | "pending" / "approved" / "denied". Defaults to "approved" on the DB side for legacy rows. |
| `start_at` | timestamptz | |
| `end_at` | timestamptz | |
| `all_day` | boolean | |
| `decided_by` | uuid | Lead/admin who decided the request. |
| `decided_at` | timestamptz | |
| `decision_note` | text | |
| `audit_log` | jsonb | Append-only. Lives as snake_case in-memory (intentional - see translator note). |
| `created_by` | text | |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |
| `deleted_at` | timestamptz | |
| `deleted_by` | text | |

**Translator mapping** (line 2594-2609).

### `announcement_banners`

Short-lived ops broadcasts.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `message` | text | Banner text. |
| `facility` | text | Scope (passthrough). |
| `starts_at` | timestamptz | |
| `ends_at` | timestamptz | "Stop now" sets this to current time. |
| `created_by` | text | Sign-in name of creator. |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Translator mapping** (line 2393-2398).

Banners are the only entity that uses real `DELETE` instead of
soft-delete (line 7063-7068, Patch E).

### `notifications`

Trainer-targeted server-authored messages. Distinct subscription
pattern: per-trainer filtered channel rather than the shared
`app-changes` channel.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. |
| `target_trainer_id` | uuid | Soft FK to `trainers.id`. Subscription filter. |
| `type` | text | "consult_assigned" / "consult_unassigned" / "time_off_requested" / "sub_admin_assigned" / "package_expiring". |
| `payload` | jsonb | Type-specific. Convention: `dedup_key` for sweep-style triggers. |
| `read_at` | timestamptz | Null until the trainer marks read. |
| `created_at` | timestamptz | |

No `updated_at` column. The translator (line 2567-2586) is custom
specifically to avoid auto-stamping one - the standard
`makeFieldTranslator` would break the patch path that flips
`read_at`.

### `settings`

Key-value store. Today this holds one row keyed `admin_pin` with the
Front Desk PIN as the value. Future config rows can land here without
migrations.

| Column | Type | Notes |
|---|---|---|
| `key` | text | PK. The on-conflict target. |
| `value` | jsonb | Arbitrary payload. |
| `updated_at` | timestamptz | |

Used via the `makeSettingsRow` factory (line 2693). Not in any
realtime publication - settings are read on demand.

---

## JSONB shapes

These are the most-referenced JSONB shapes in the schema. Treat
this section as the source of truth when working with these fields;
keep it in lockstep with the in-code constructors.

### `clients.packages[]`

Array of package records. Constructed in `buildSeedClients`
(line 3521) and `addPackageToClient` (line 3866). Mutated by the
package CRUD flow.

```
{
  id: uuid,
  type: text,                  // canonical taxonomy, e.g. "CMRC-PT-10"
  template_id: text,           // PT_PACKAGES_BY_FACILITY entry id
  location: text,              // "CMRC" or "Baca"
  sessions: integer,           // package size
  price: number,
  amountPaid: number,
  purchaseDate: text,          // YYYY-MM-DD
  paymentType: text,           // "Card" / etc
  source: text,                // "seed" / "rectrac_import" / "rectrac_reup" / etc
  is_pairs: boolean,
  is_consult: boolean,
  is_intro: boolean,
  validDays: integer,          // expiration window; drives package_expiring sweep
  // Lifecycle fields, present when applicable:
  deletedAt: timestamptz,
  deletedBy: text,
  restoredAt: timestamptz,
  restoredBy: text
}
```

**Notes.**
- `sessionsUsed`, `sessionsRemaining`, `is_active` were dropped per
  the Sprint K decision. Remaining sessions are computed live from
  the `sessions[]` array via `sessionsRemaining()`.
- The synthesized `type` value is what existing code groups by.
- Consult rows and zero-session rows have no `validDays` and are
  excluded from the `package_expiring` sweep.
- Per-template metadata (`is_pairs`, `is_consult`, `is_intro`)
  drives downstream rendering and aggregation.

### `clients.sessions[]`

Array of PT session records. Constructed in `addSession`
(line 6507), `createRecurringSessions` (line 6629), and
`rescheduleSeriesFromHere` (line 6695).

```
{
  id: uuid,
  date: text,                  // YYYY-MM-DD
  time: text,                  // HH:MM 24h
  status: text,                // "scheduled" / "attended" / "no_show" / "late_cancel" / "excused"
  note: text,
  trainerName: text,
  durationHours: number,       // 1 or 0.5 (chosen at log time)
  scheduledBy: text,           // sign-in name at create time
  scheduledAt: timestamptz,
  series_id: uuid,             // Sprint M recurring series link; absent on one-offs
  // Sign-off fields, present when status !== 'scheduled':
  signature: text,             // base64
  signedAt: timestamptz,
  clientSignedAt: timestamptz,
  // Service recovery fields, present when applicable:
  recoveryLogged: boolean,
  recoveryDuration: number,    // hours, capped at lost-session duration
  recoveryNote: text
}
```

**Notes.**
- `series_id` is set only on rows created via the recurring-series
  helpers. The whole series shares one uuid so "this and all future"
  operations can scope by it.
- `package_id` is referenced in CLAUDE.md as planned ("will be added
  by multi-package picker spec") but is NOT present in code today.
- Status transitions and consumption math:
  - `attended`: both trainer and client signed. Counts against the package.
  - `no_show`: trainer signed, client absent. Full session loss.
  - `late_cancel`: under 24 hr cancellation. Full session loss.
  - `excused`: note preserved, no package loss.
- `durationHours` is the per-row consumption unit. Uniform across
  a recurring series.

### `clients.audit_log[]`

Append-only audit array. Same shape applies to `audit_log` on
`trainers`, `leads`, `closures`, `classes`, and anything else that
goes through `appendAuditEntry` (line 3810).

```
{
  id: uuid,
  ts: timestamptz,
  actor: text,                 // session.trainer_name or session.name, or "unknown"
  actor_id: uuid,              // session.trainer_id; null for Front Desk
  action: text,                // see vocabulary below
  entity_type: text,           // "client" / "trainer" / "lead" / "class" / "closure" / "time_off"
  target_id: uuid,
  before: object,              // null on create
  after: object,               // null on hard-delete
  changes: object,             // populated for 'update' and 'package_edited' actions only
  amount: number               // session consumption delta; populated for session_* and recurring_* actions
}
```

**Log size cap.** 100 entries per record. On append, the head is
trimmed: `log = log.slice(log.length - 100)`. This is a per-record
ring buffer, not a global audit table.

**Action vocabulary observed in code (clients).** `session_create`,
`session_signoff`, `session_delete`, `package_added`,
`package_edited`, `package_deleted`, `package_restored`,
`package_hard_deleted`, `recurring_create`, `recurring_reschedule`,
`recurring_cancel_all`, `consult_claim`, `soft_delete`, `restore`,
`recovery_logged`, `dedup_cleanup`, `migrate_package_type_prefix`,
`strip_writeonly_pkg_fields`.

**Action vocabulary observed in code (other entities).**
`closure_added`, `closure_deleted`, `timeoff_requested`,
`timeoff_deleted`, `lead_status_change`, `lead_reassigned`,
`update`, `attendance_logged`, `attendance_deleted`, plus the
trainer-specific `soft_delete` / `restore`.

### Other JSONB columns

**`classes.sub_assignments[]`**. Sub coverage state per occurrence.
Each entry: `{date, originalInstructor, subInstructor, claimedBy,
requestedBy, requestedAt, claimedAt, status}`.

**`classes.attendance[]`**. Per-occurrence attendance. Each entry:
`{date, instructor, count, notes, signedAt}`.

**`leads.status_history[]`**. Status timeline. Each entry:
`{ts, status, by, note}`. Walked by the audit cascade query and
by the lead detail view's history strip.

**`schedule_versions.data`** (object, not array):
`{endDate, activatedAt, classes: [...]}`. The nested `classes` array
is itself a snapshot of the schedule at version time.

**`wros.data`**. Everything not promoted to flat columns. The
`post` sub-object is always reconstructed as a non-null object on
read, even when all fields are null - components access
`wro.post.specialistName` without null-guarding `wro.post` itself.

**`trainers.previous_names`** (array): `[{name, renamed_at}, ...]`.

**`notifications.payload`**. Per-type. Convention: a `dedup_key`
field on sweep-style notifications (e.g. `package_expiring`) so
the in-memory `existsForTrainer` check can avoid duplicate emits.

---

## Indices and constraints

Indices and uniqueness constraints are not documented in the
codebase. Known constraints inferred from code patterns:

- `trainers_name_unique` on `trainers.name`. Required by the
  upsert-by-name save pattern (`onConflict: 'name'` at line 2774).
- `id` PK on every table. The `onConflict: 'id'` upsert pattern is
  used universally elsewhere.
- `settings_key_unique` (or PK on `key`) on `settings.key`. Required
  by `onConflict: 'key'` at line 2717.

Other indices (foreign-key-style lookups, query optimization indices)
exist server-side but are not referenced in code. Documenting them
is deferred to the future regeneration script.

---

## Soft FK relationships (by convention, not constraint)

The schema has no formal foreign key constraints. The following
relationships are enforced by code only:

- `clients.from_queue_id` → `leads.id`
- `clients.trainer_name` → `trainers.name` (cascade-updated on rename via `RenameTrainerModal`)
- `clients.rectrac_member_id` → external RecTrac system (no in-DB target)
- `classes.instructor` → `trainers.name` (cascade-updated on rename)
- `classes.schedule_version_id` → `schedule_versions.id`
- `leads.assigned_to` → `trainers.name` (cascade-updated on rename)
- `leads.converted_to_client_id` → `clients.id`
- `leads.from_wro_id` → `wros.id`
- `member_contacts.trainer_name` → `trainers.name` (cascade-updated on rename)
- `referrals.referred_by` → `trainers.name` (cascade-updated on rename)
- `referrals.client_id` → `clients.id`
- `trainer_time_off.trainer_id` → `trainers.id`
- `notifications.target_trainer_id` → `trainers.id`
- `admin_items.assignees[]` → `trainers.name` (cascade-updated on rename via flat text[])

The cascade query at line 22866-22956 of the tracker is the
authoritative reference for which fields participate in the rename
cascade and which are denormalized name copies.

---

## How this is maintained

- **On any schema change.** Whoever applies the migration updates
  this doc in the same commit. If the migration is run via the
  Supabase SQL editor without a corresponding code change, the doc
  update is its own commit referencing the SQL.
- **On translator changes.** When a `translate.X.toSupabase` /
  `fromSupabase` mapping changes, the matching per-table section here
  gets updated.
- **On new JSONB shape additions.** Add a sub-section under "JSONB
  shapes" with the in-code constructor reference.
- **Cross-referenced from** `ARCHITECTURE.md` (for the why) and
  `DECISIONS.md` (for the ADRs that drove the current shape).
- **Future regeneration.** A script that pulls `information_schema`
  and emits this doc automatically is a Bucket 3 followup. Once it
  exists, this doc becomes the diff target rather than the primary
  source.

---

*Maintained by Reagan. Questions and corrections: reaganmrrw@gmail.com.*
