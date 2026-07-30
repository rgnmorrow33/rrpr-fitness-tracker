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

## Before you write or execute a spec

Stale claims in this repo have caused real damage twice. v4.48 found this file
asserting the opposite of what the database does. On July 29 a spec arrived
written against a v4.45 copy of a log that had said v4.48 for two weeks, and
following it literally would have written duplicate version entries into the
canonical file. Two rules exist to stop a third:

1. **`docs/Fitness_Tracker_Update_Log.md` is the canonical log.** Any
   `Fitness_Tracker_Update_Log.docx` anywhere - project files, Drive, a chat
   upload - is a point-in-time snapshot and is probably stale. Never write or
   execute a spec off one. Confirm live version state from the log header plus
   `git log --oneline -5` and `git tag | tail -3`, and say out loud which
   version the work is written against before starting.

2. **Every claim in this file about live database or infrastructure state
   carries a `Verified: YYYY-MM-DD` stamp and the query that re-checks it.**
   If you are about to rely on an unstamped claim, re-verify it and stamp it.
   If a stamp predates the newest file in `migrations/`, treat the claim as
   unverified until you have run its query.

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
Docs in `/docs` (SCHEMA.md, ARCHITECTURE.md, DECISIONS.md, BACKLOG.md)
reference code in `RoundRock_Fitness_Tracker.html` by function name or
section anchor, never by line number. The single-file app drifts; line
refs go stale within days.

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

The app uses a storage adapter (the `storage` object near the top of
the embedded script, just after the config constants) that wraps all
reads/writes. Two modes: 'localStorage' and 'supabase'. Currently in
'supabase' mode.

Supabase project: ofezaezijafglyjmisgz.supabase.co
Anon key is committed in the file (designed-public). Since v4.46 that is
actually safe: RLS is enabled on every public table and anon holds exactly
one privilege in the whole schema. The key identifies a role, it does not
grant access. See Security posture.

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

CRITICAL GOTCHA - a listener receives NOTHING unless its table is in the
supabase_realtime publication. Attaching a client listener alone does nothing.
To make a table sync live you must ADD IT TO the publication. Do not design a
feature assuming a table pushes live without confirming it is in the
publication.

The publication (verified 2026-07-14 against the live database) contains
exactly 5 tables:

    classes, clients, leads, notifications, trainer_time_off

The app matches this. PUBLISHED_TABLES (in the realtime useEffect) gates live
channels to the 4 entity tables - clients, classes, leads, trainer_time_off -
and notifications rides its own per-trainer channel. The other 8 entities stay
in the `subs` list for the wake catch-up refetch but get NO channel, because a
channel on an unpublished table receives nothing and only adds
subscribe/sweep/reconnect traffic.

Channels are PER TABLE ('table-changes-<table>'), not one shared channel.
supabase-js v2 does not reliably fan multiple postgres_changes bindings out on
one channel - the old single 'app-changes' channel reached SUBSCRIBED and
delivered zero events (fixed v4.33).

Prior versions of this file claimed the publication held only 2 tables
(notifications, trainer_time_off, "verified June 17") and that clients /
classes / leads converge only on reload. That was wrong, and it was wrong in
the dangerous direction: those three DO push live. Corrected v4.48 by querying
pg_publication_tables directly. Re-verify with:

    select tablename from pg_publication_tables
    where pubname = 'supabase_realtime' order by tablename;

Full mechanics (reload chain, self-write echo tolerance, reconnect,
wake sweeps, notifications channel, sync indicator) live in
ARCHITECTURE.md section 6. Load it before touching realtime code.

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
- Production site: pardfitnesstracker2.netlify.app (Selisa's iPads).
  Backend: Supabase project ofezaezijafglyjmisgz. This is the LIVE site -
  a push to main auto-deploys straight to the production iPads. There is no
  separate staging URL right now, so treat every push as production.
- Stale/abandoned: pardfitnesstracker.netlify.app is an old v2.x
  localStorage-only build with no Supabase backend (do not use or push to it).
  candid-cendol-66c876 is dead (404). (Verified July 9 2026 by reading each
  deployed site's served HTML - the prior "pardfitnesstracker = prod,
  pardfitnesstracker2 = test" labels were inverted and dangerous.)
- Local repo: C:\Docs\rrpr-fitness-tracker

Workflow:
1. Reagan describes change in Claude Code
2. Claude Code edits the file
3. node --check on embedded JS
4. git add, commit with descriptive message, git push
5. Netlify auto-deploys in ~30 seconds
6. Selisa verifies on production iPad

Pre-push gates. Three checks run before every push and block it on failure:
node --check on the embedded JS, the tag-before-push check, and (since
v4.55) a version-match check that blocks unless `APP_VERSION` (the config
constant near STORAGE_MODE) equals the trailing `/* vX.Y */` footer
comment - so the Login-screen build indicator can't silently drift into a
stale claim the way this file itself has twice. Update both together. They
run two ways - through Claude Code automatically (.claude/settings.json), and
as a native git pre-push hook for manual terminal pushes. The git hook is
tracked in githooks/ but core.hooksPath is local config, so each clone
enables it ONCE:

    git config core.hooksPath githooks

Do NOT rename the tracker file. The netlify.toml redirect handles
serving RoundRock_Fitness_Tracker.html at the root URL.

Do NOT put the repo in a OneDrive-synced folder. Conflicts with
Git's .git folder.

## Version tagging (tag on release)

Every shipped version gets a lightweight git tag at release. Tag BEFORE
pushing the version's commits, then push the branch, then push the tag:

    git tag v4.32
    git push
    git push origin v4.32

Tag-before-push is enforced: the pre-push hook (see Deployment pipeline)
blocks any push whose commits reference a `vX.Y` that has no matching tag.
The tag still marks the exact commit that goes live as that version.

Why: versions otherwise live only as inline comments and in the update-log docx,
which makes version-to-version history archaeology (this caused the v4.30/v4.31
reconstruction problem). Tags give the log scaffold (`npm run log:scaffold`) clean
ranges with no argument, let the SCHEMA.md checker stamp drift reports against a
known version, and mean future-me never has to guess whether a version existed.

Rule: a version is not done until it is tagged. The update-log entry and the tag
are the two closing acts of shipping a version. If you used the tag+scaffold
helper (`npm run release:tag -- v4.32`), the tag is handled; otherwise tag by hand.

Tags are cheap and local-cost-free. This is a habit, not a process. No annotated
tags, no release notes in the tag, no signing. Just `git tag vX.Y`.

## Required field validation

- Name required on new client and WRO intake
- At least ONE of email or phone required (both is fine, minimum one)
- Email must look like email@domain.something when provided
- Phone must have at least 10 digits when stripped
- Existing records grandfathered

## Deferred work

Deferred work (cleanup pile, refactor targets, unbuilt features) lives
in docs/BACKLOG.md, load on demand.

## Security posture

**Verified: 2026-07-29** against the live database. This section said the
exact opposite until then, having survived unchanged through the v4.46
lockdown that made it false. Do not trust it without re-running the queries
below if the stamp is older than the newest file in `migrations/`.

**RLS is ENABLED on all 19 public tables.** Zero tables with RLS off, 55
policies, zero `allow all` policies. Migrations 0002 and 0004 through 0008
did this; 0003 was retired and never run. Re-verify:

    select count(*) filter (where rowsecurity) as on,
           count(*) filter (where not rowsecurity) as off
    from pg_tables where schemaname = 'public';

**anon holds exactly ONE privilege in the entire public schema:**
`trainer_directory:SELECT`. That view is names only - no PINs, no hashes, no
client data. Everything else requires an authenticated session. Re-assert
this after any migration that creates a table or view (see 0008). Re-verify:

    select table_name, privilege_type from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon';

**PINs are bcrypt, verified server-side.** `trainers.pin` is NULL on every
row - the column is a vestige, not storage. `trainers.pin_set` is the boolean
the UI reads. Verification and setting go through
`verify_trainer_pin` / `verify_admin_pin` / `set_trainer_pin` / `set_admin_pin`
(supported by `_pin_record` and `_pin_locked`). `settings.admin_pin` holds a
bcrypt hash. No plaintext PIN and no hash ever returns to the client. PUBLIC
execute on the setters was revoked in 0007.

**What RLS does NOT do here: row ownership.** Any signed-in trainer can update
any client's row. That is structural, not laziness - sessions, packages and
attendance live inside JSONB on the parent row (ADR-0004), so "log a session"
IS "UPDATE the whole clients row." Acceptable for an internal team tool.
Revisit before APC.

**Client-side `ctx.can('<permission>')` is still the permission model** for who
can do what inside the app. The difference since v4.46 is that the DB layer is
no longer wide open behind it.

## Out of scope

- Payment processing (RecTrac handles)
- Member self-service portal (RecTrac handles)
- Clinical PT EMR (PTEverywhere is separate, not connected to this app)
- Email/SMS infrastructure
